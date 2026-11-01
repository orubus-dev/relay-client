import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Local message database — the source of truth on the device.
/// The network layer only EVER fetches NEW messages (cursor-based) and
/// realtime INSERTs; everything else reads from here. Works on Android and
/// Windows via sqlite3_flutter_libs.
class LocalDb {
  Database? _db;

  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _openAt(dir.path);
    } catch (_) {
      // documents dir unavailable (rare Android cold starts / sandboxed CI):
      // fall back to the temp dir before giving up — the app is useless
      // without the local database, but a temp db beats a guaranteed crash.
      final tmp = await getTemporaryDirectory();
      _openAt(p.join(tmp.path, 'relay_fallback'));
    }
  }

  void _openAt(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _db = sqlite3.open(p.join(dirPath, 'relay.db'));
    _migrate();
  }

  void _migrate() {
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS chats (
        id TEXT PRIMARY KEY,
        name TEXT,
        type TEXT,
        avatar_url TEXT,
        last_message_text TEXT,
        last_message_at TEXT,
        last_message_sender_id TEXT,
        unread_count INTEGER DEFAULT 0,
        request_status TEXT,
        is_pinned INTEGER DEFAULT 0,
        updated_at TEXT
      );
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        sender_name TEXT,
        sender_avatar TEXT,
        type TEXT DEFAULT 'text',
        content TEXT,
        media_url TEXT,
        media_key TEXT,
        mime_type TEXT,
        file_name TEXT,
        duration_seconds INTEGER,
        reply_to_id TEXT,
        reply_to_name TEXT,
        reply_to_content TEXT,
        delivery_state TEXT DEFAULT 'sent',
        is_edited INTEGER DEFAULT 0,
        is_deleted INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, created_at);
      CREATE TABLE IF NOT EXISTS sync_cursor (
        chat_id TEXT PRIMARY KEY,
        last_synced_at TEXT,
        history_loaded INTEGER DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS kv (
        k TEXT PRIMARY KEY,
        v TEXT
      );
    ''');
  }

  Database get _d {
    final db = _db;
    if (db == null) {
      throw StateError('LocalDb.init() has not completed — chat storage unavailable');
    }
    return db;
  }

  // ---------------- diagnostics (Profile → Developer) ----------------

  /// Cached message rows (-1 when the DB is not open).
  int messageCount() {
    if (!isReady) return -1;
    try {
      return _d.select('SELECT COUNT(*) AS c FROM messages').first['c'] as int;
    } catch (_) {
      return -1;
    }
  }

  /// Cached chat rows (-1 when the DB is not open).
  int chatCount() {
    if (!isReady) return -1;
    try {
      return _d.select('SELECT COUNT(*) AS c FROM chats').first['c'] as int;
    } catch (_) {
      return -1;
    }
  }

  // ---------------- chats ----------------

  void upsertChat(Map<String, Object?> chat) {
    if (!isReady) return;
    _d.execute('''
      INSERT INTO chats (id, name, type, avatar_url, last_message_text, last_message_at,
        last_message_sender_id, unread_count, request_status, is_pinned, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = COALESCE(excluded.name, chats.name),
        avatar_url = COALESCE(excluded.avatar_url, chats.avatar_url),
        last_message_text = COALESCE(excluded.last_message_text, chats.last_message_text),
        last_message_at = COALESCE(excluded.last_message_at, chats.last_message_at),
        last_message_sender_id = COALESCE(excluded.last_message_sender_id, chats.last_message_sender_id),
        unread_count = excluded.unread_count,
        request_status = COALESCE(excluded.request_status, chats.request_status),
        is_pinned = COALESCE(excluded.is_pinned, chats.is_pinned),
        updated_at = COALESCE(excluded.updated_at, chats.updated_at)
    ''', [
      chat['id'], chat['name'], chat['type'], chat['avatar_url'], chat['last_message_text'],
      chat['last_message_at'], chat['last_message_sender_id'], chat['unread_count'] ?? 0,
      chat['request_status'], (chat['is_pinned'] as bool? ?? false) ? 1 : 0, chat['updated_at'],
    ]);
  }

  /// True when the database opened successfully — UI checks this instead of
  /// crashing on an unguarded `_d` access.
  bool get isReady => _db != null;

  void clearUnread(String chatId) {
    if (!isReady) return;
    _d.execute('UPDATE chats SET unread_count = 0 WHERE id = ?', [chatId]);
  }

  List<Map<String, Object?>> listChats() {
    // a dead db must degrade to an empty list, never throw inside a
    // postFrameCallback (that used to be a guaranteed launch crash)
    if (!isReady) return const [];
    final rows = _d.select('SELECT * FROM chats ORDER BY COALESCE(last_message_at, updated_at) DESC');
    return rows.map((r) => r).toList();
  }

  // ---------------- messages ----------------

  /// Insert messages, skipping duplicates. Returns how many were NEW.
  int insertMessages(List<Map<String, Object?>> msgs) {
    if (!isReady) return 0;
    const insertSql = '''
      INSERT OR IGNORE INTO messages (id, chat_id, sender_id, sender_name, sender_avatar,
        type, content, media_url, media_key, mime_type, file_name, duration_seconds,
        reply_to_id, reply_to_name, reply_to_content, delivery_state, is_edited, is_deleted, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''';
    var inserted = 0;
    for (final m in msgs) {
      _d.execute(insertSql, [
        m['id'], m['chat_id'], m['sender_id'], m['sender_name'], m['sender_avatar'],
        m['type'] ?? 'text', m['content'], m['media_url'], m['media_key'], m['mime_type'],
        m['file_name'], m['duration_seconds'], m['reply_to_id'], m['reply_to_name'],
        m['reply_to_content'], m['delivery_state'] ?? 'sent', (m['is_edited'] as bool? ?? false) ? 1 : 0,
        (m['is_deleted'] as bool? ?? false) ? 1 : 0, m['created_at'],
      ]);
      if (_d.updatedRows > 0) inserted++;
    }
    return inserted;
  }

  void updateMessageDelivery(String messageId, String state) {
    if (!isReady) return;
    _d.execute('UPDATE messages SET delivery_state = ? WHERE id = ?', [state, messageId]);
  }

  List<Map<String, Object?>> listMessages(String chatId, {int limit = 500}) {
    if (!isReady) return const [];
    return _d
        .select('SELECT * FROM messages WHERE chat_id = ? AND is_deleted = 0 ORDER BY created_at ASC LIMIT ?',
            [chatId, limit])
        .toList();
  }

  // ---------------- sync cursor ----------------

  ({String? lastSyncedAt, bool historyLoaded}) cursorFor(String chatId) {
    if (!isReady) return (lastSyncedAt: null, historyLoaded: false);
    final rows = _d.select('SELECT last_synced_at, history_loaded FROM sync_cursor WHERE chat_id = ?', [chatId]);
    if (rows.isEmpty) return (lastSyncedAt: null, historyLoaded: false);
    return (
      lastSyncedAt: rows.first['last_synced_at'] as String?,
      historyLoaded: (rows.first['history_loaded'] as int? ?? 0) == 1,
    );
  }

  void saveCursor(String chatId, {String? lastSyncedAt, bool? historyLoaded}) {
    if (!isReady) return;
    final c = cursorFor(chatId);
    _d.execute('''
      INSERT INTO sync_cursor (chat_id, last_synced_at, history_loaded) VALUES (?, ?, ?)
      ON CONFLICT(chat_id) DO UPDATE SET
        last_synced_at = ?, history_loaded = ?
    ''', [
      chatId,
      lastSyncedAt ?? c.lastSyncedAt,
      (historyLoaded ?? c.historyLoaded) ? 1 : 0,
      lastSyncedAt ?? c.lastSyncedAt,
      (historyLoaded ?? c.historyLoaded) ? 1 : 0,
    ]);
  }

  // ---------------- kv / identity of the account ----------------

  String? kvGet(String key) {
    if (!isReady) return null;
    final rows = _d.select('SELECT v FROM kv WHERE k = ?', [key]);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  void kvSet(String key, String value) {
    if (!isReady) return;
    _d.execute('INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = ?', [key, value, value]);
  }

  Future<void> wipe() async {
    _d.execute('DELETE FROM messages; DELETE FROM chats; DELETE FROM sync_cursor;');
  }
}
