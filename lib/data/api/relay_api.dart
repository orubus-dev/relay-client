import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:supabase/supabase.dart';

import '../core/constants.dart';
import '../data/crypto/e2ee_service.dart';
import '../util/encoding.dart';

/// Thin API layer over the same Supabase backend the web client uses.
/// All chat content flows through the E2EE service — the server only ever
/// stores ciphertext.
class RelayApi {
  final SupabaseClient sb;
  final E2eeService e2ee;

  RelayApi({required this.sb, required this.e2ee});

  String? get myProfileId => sb.auth.currentUser?.id;

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  Future<Uint8List> _readFileBytes(String path) async => File(path).readAsBytes();

  // ---------------- profile ----------------

  Future<Map<String, dynamic>?> fetchProfile(String userId) async {
    final res = await sb
        .from('profiles')
        .select()
        .or('auth_user_id.eq.$userId,id.eq.$userId')
        .maybeSingle();
    return res == null ? null : Map<String, dynamic>.from(res);
  }

  Future<void> updateProfile(String profileId, Map<String, dynamic> patch) async {
    await sb.from('profiles').update(patch).eq('id', profileId);
  }

  Future<bool> usernameAvailable(String username) async {
    final data = await sb.rpc('username_available', params: {'p_username': username});
    return data == true;
  }

  // ---------------- chats ----------------

  Future<List<Map<String, dynamic>>> fetchChats() async {
    final me = myProfileId;
    if (me == null) return [];
    final memberships = await sb
        .from('conversation_members')
        .select('conversation_id, unread_count, is_pinned, request_status, conversations(*)')
        .eq('profile_id', me)
        .eq('status', 'active');
    final chats = <Map<String, dynamic>>[];
    for (final m in (memberships as List).cast<Map<String, dynamic>>()) {
      final conv = m['conversations'];
      if (conv == null) continue;
      chats.add({
        'id': m['conversation_id'],
        'unread_count': m['unread_count'] ?? 0,
        'is_pinned': m['is_pinned'] ?? false,
        'request_status': m['request_status'] ?? 'accepted',
        'conversation': Map<String, dynamic>.from(conv),
      });
    }
    return chats;
  }

  Future<List<Map<String, dynamic>>> fetchMessages(String conversationId, {int limit = 200}) async {
    final data = await sb.rpc('get_conversation_messages', params: {
      'p_conversation_id': conversationId,
      'p_limit': limit,
    });
    return (data as List? ?? []).cast<Map<String, dynamic>>();
  }

  /// Send with E2EE: DMs → R1 envelope; groups/channels → R2 fan-out.
  Future<Map<String, dynamic>?> sendMessageRaw(String conversationId, String content, String type) async {
    final me = myProfileId;
    if (me == null) throw StateError('Not signed in');
    final members = await sb
        .from('conversation_members')
        .select('profile_id')
        .eq('conversation_id', conversationId)
        .eq('status', 'active');
    final peers = (members as List)
        .map((r) => (r as Map<String, dynamic>)['profile_id'] as String)
        .where((p) => p != me)
        .toList();

    String wire;
    if (peers.length <= 1) {
      final peer = peers.firstOrNull;
      if (peer == null) {
        wire = content; // solo conversation — nothing to encrypt against
      } else {
        wire = await e2ee.encryptFor(me, conversationId, peer, content);
      }
    } else {
      wire = await e2ee.encryptFanout(me, conversationId, peers, content);
    }

    final res = await sb.rpc('send_conversation_message', params: {
      'p_conversation_id': conversationId,
      'p_recipient_profile_id': null,
      'p_content': wire,
      'p_message_type': type,
      'p_reply_to_message_id': null,
      'p_media_url': null,
      'p_file_name': null,
      'p_is_forwarded': false,
    });
    return res == null ? null : Map<String, dynamic>.from(res as Map);
  }

  Future<void> markRead(String conversationId) async {
    await sb.rpc('mark_messages_status', params: {
      'p_conversation_id': conversationId,
      'p_status': 'read',
    });
  }

  /// Client-side encrypted media upload — bucket stores AES-256-GCM ciphertext
  /// only; the key rides INSIDE the ratchet-encrypted message payload.
  Future<Map<String, dynamic>> uploadEncryptedFile(String filePath, {String mime = 'audio/mp4'}) async {
    final me = myProfileId;
    if (me == null) throw StateError('Not signed in');
    final bytes = await _readFileBytes(filePath);
    final key = _randomBytes(32);
    final iv = _randomBytes(12);

    final secretKey = SecretKey(key);
    final box = await AesGcm.with256bits().encrypt(bytes, secretKey: secretKey, nonce: iv);
    final ciphertext = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);

    final path = '$me/${DateTime.now().millisecondsSinceEpoch}_VoiceNote.m4a.enc';
    await sb.storage.from('chat-media').uploadBinary(
          path,
          ciphertext,
          fileOptions: const FileOptions(contentType: 'application/octet-stream', upsert: false),
        );
    final signed = await sb.storage.from('chat-media').createSignedUrl(path, 60 * 60 * 24 * 365);
    return {'url': signed, 'mediaKey': B64u.encode(key), 'size': bytes.length};
  }

  // ---------------- communities / channels ----------------

  Future<List<Map<String, dynamic>>> listMyCommunities() async {
    final me = myProfileId;
    if (me == null) return [];
    final rows = await sb
        .from('community_members')
        .select('communities(*)')
        .eq('profile_id', me)
        .eq('status', 'active');
    return (rows as List)
        .map((r) => (r as Map<String, dynamic>)['communities'])
        .whereType<Map<String, dynamic>>()
        .map((c) => Map<String, dynamic>.from(c))
        .toList();
  }

  Future<List<Map<String, dynamic>>> listChannels(String communityId) async {
    final rows = await sb
        .from('community_channels')
        .select()
        .eq('community_id', communityId)
        .order('sort_order');
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<String> openChannelConversation(String channelId) async {
    final data = await sb.rpc('get_or_create_channel_conversation', params: {'p_channel_id': channelId});
    return data as String;
  }

  Future<Map<String, dynamic>?> createChannel(String communityId, String name, String type) async {
    final data = await sb.rpc('create_channel', params: {
      'p_community_id': communityId,
      'p_name': name,
      'p_channel_type': type,
      'p_description': null,
    });
    return data == null ? null : Map<String, dynamic>.from(data as Map);
  }

  Future<List<Map<String, dynamic>>> listCommunityMembers(String communityId) async {
    final rows = await sb
        .from('community_members')
        .select('profile_id, is_owner, is_moderator, profiles(display_name, full_name, username, avatar_url)')
        .eq('community_id', communityId)
        .eq('status', 'active');
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<void> joinCommunity(String communityId) => sb.rpc('join_community', params: {'p_community_id': communityId});

  // ---------------- notifications ----------------

  Future<List<Map<String, dynamic>>> fetchNotifications() async {
    final me = myProfileId;
    if (me == null) return [];
    final rows = await sb
        .from('notifications')
        .select()
        .eq('profile_id', me)
        .order('created_at', ascending: false)
        .limit(60);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<void> markAllNotificationsRead() async {
    final me = myProfileId;
    if (me == null) return;
    await sb.from('notifications').update({'is_read': true}).eq('profile_id', me).eq('is_read', false);
  }

  // ---------------- realtime ----------------

  RealtimeChannel subscribeMessages(String conversationId, void Function(Map<String, dynamic>) onInsert) {
    return sb
        .channel('client-msgs:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(column: 'conversation_id', value: conversationId),
          callback: (payload) => onInsert(Map<String, dynamic>.from(payload.newRecord)),
        )
        .subscribe();
  }

  RealtimeChannel subscribeNotifications(String profileId, void Function() onChange) {
    return sb
        .channel('client-notifs:$profileId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(column: 'profile_id', value: profileId),
          callback: (_) => onChange(),
        )
        .subscribe();
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
