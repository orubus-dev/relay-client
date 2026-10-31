import 'dart:convert';

import 'package:realtime_client/realtime_client.dart';
import 'package:supabase/supabase.dart';

import '../api/relay_api.dart';
import '../crypto/e2ee_service.dart';
import 'local_db.dart';

/// Cursor-based sync: the device database is the source of truth; the network
/// only contributes NEW messages (first open pulls history once, after that
/// only rows newer than the cursor, plus realtime INSERTs).
class SyncEngine {
  final RelayApi api;
  final LocalDb db;
  RealtimeChannel? _notifChannel;

  SyncEngine({required this.api, required this.db});

  /// Pull chats + their newest messages into the local db.
  Future<void> bootstrap() async {
    final me = api.myProfileId;
    if (me == null) return;
    final chats = await api.fetchChats();
    for (final c in chats) {
      final conv = (c['conversation'] as Map<String, dynamic>?) ?? {};
      db.upsertChat({
        'id': c['id'],
        'name': conv['name'],
        'type': conv['conversation_type'] ?? conv['type'],
        'avatar_url': conv['avatar_url'],
        'last_message_text': conv['last_message_preview'],
        'last_message_at': conv['last_message_at']?.toString(),
        'last_message_sender_id': conv['last_message_sender_id'],
        'unread_count': c['unread_count'] ?? 0,
        'request_status': c['request_status'],
        'is_pinned': c['is_pinned'] ?? false,
        'updated_at': conv['updated_at']?.toString(),
      });
    }
  }

  /// Fetch only NEW messages for a conversation into the local db.
  /// Decrypts ratchet envelopes before persisting — plaintext at rest stays
  /// device-local; the network never carried it.
  Future<int> syncMessages(String conversationId, {bool fullHistory = false}) async {
    final me = api.myProfileId;
    if (me == null) return 0;
    final cursor = db.cursorFor(conversationId);
    final rows = await api.fetchMessages(conversationId, limit: fullHistory || !cursor.historyLoaded ? 200 : 60);

    final fresh = <Map<String, Object?>>[];
    String? newestAt = cursor.lastSyncedAt;
    for (final r in rows) {
      final createdAt = (r['created_at'] ?? '') as String;
      if (!fullHistory && cursor.lastSyncedAt != null && createdAt.compareTo(cursor.lastSyncedAt!) <= 0) {
        continue; // already stored — only NEW messages cross the wire
      }
      final senderId = (r['sender_id'] ?? '') as String;
      final type = (r['message_type'] ?? 'text') as String;
      final rawContent = (r['content'] ?? '') as String;
      String content = rawContent;
      String? mediaUrl = r['media_url'] as String?;
      String? mediaKey;
      String? mime;
      String? fileName = r['file_name'] as String?;
      String? replyToId;
      String? replyToName;
      String? replyToContent;

      if (rawContent.isNotEmpty && (api.e2ee.isEnvelope(rawContent) || api.e2ee.isFanout(rawContent))) {
        try {
          final payloadJson = await api.e2ee.decryptAny(me, conversationId, senderId, rawContent);
          if (payloadJson == null) {
            content = '🔒 Encrypted message';
          } else {
            final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
            final kind = payload['k'];
            if (kind == 'r') {
              // Session-reset control message — protocol plumbing, never stored.
              continue;
            }
            if (kind == 't' || kind == 's') {
              content = (payload['t'] ?? '') as String;
            } else if (kind == 'm') {
              content = type == 'image' ? 'Photo' : type == 'voice_note' ? 'Voice note' : 'Attachment';
              mediaUrl = (payload['u'] ?? mediaUrl) as String?;
              mediaKey = payload['key'] as String?;
              mime = payload['mime'] as String?;
              fileName = (payload['name'] ?? fileName) as String?;
            }
            // reply metadata rides inside the encrypted payload (r=id, rn=name, rt=snippet)
            replyToId = payload['r'] as String?;
            replyToName = payload['rn'] as String?;
            replyToContent = payload['rt'] as String?;
          }
        } on RelaySessionDead {
          content = '🔒 Encrypted message (cannot decrypt on this device)';
          // Session-reset protocol: re-initiate with a silent control envelope
          // so BOTH sides converge instead of failing forever.
          try {
            final wire = await api.e2ee.buildSessionResetWire(me, conversationId, senderId);
            await api.sendWireRaw(conversationId, senderId, wire);
          } catch (_) {/* retried on next failure */}
        } catch (_) {
          content = '🔒 Encrypted message (cannot decrypt on this device)';
        }
      }

      fresh.add({
        'id': r['id'],
        'chat_id': conversationId,
        'sender_id': senderId,
        'sender_name': r['sender_name'],
        'sender_avatar': r['sender_avatar'],
        'type': type,
        'content': content,
        'media_url': mediaUrl,
        'media_key': mediaKey,
        'mime_type': mime,
        'file_name': fileName,
        'duration_seconds': null,
        'reply_to_id': replyToId ?? r['reply_to_message_id'],
        'reply_to_name': replyToName,
        'reply_to_content': replyToContent,
        'delivery_state': r['send_status'] ?? 'sent',
        'is_edited': r['is_edited'] ?? false,
        'is_deleted': r['is_deleted'] ?? false,
        'created_at': createdAt,
      });
      if (newestAt == null || createdAt.compareTo(newestAt) > 0) newestAt = createdAt;
    }

    var inserted = 0;
    if (fresh.isNotEmpty) inserted = db.insertMessages(fresh);
    db.saveCursor(conversationId, lastSyncedAt: newestAt ?? DateTime.now().toUtc().toIso8601String(), historyLoaded: true);
    return inserted;
  }

  /// Handle one realtime INSERT row (fetch-then-decrypt is unnecessary — the
  /// row already carries the envelope; decrypt + persist + let UI read local).
  Future<void> ingestRealtimeRow(Map<String, dynamic> row) async {
    final conversationId = row['conversation_id'] as String?;
    if (conversationId == null) return;
    await syncMessages(conversationId);
  }

  void subscribeNotificationsRealtime(void Function() onChange) {
    final me = api.myProfileId;
    if (me == null) return;
    _notifChannel?.unsubscribe();
    _notifChannel = api.subscribeNotifications(me, onChange);
  }
}
