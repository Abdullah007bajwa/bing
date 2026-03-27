// lib/core/storage/secure_db.dart
// SQLCipher encrypted local database.
// DB key = 256-bit random key stored in Android Keystore / iOS Secure Enclave.
// Schema: messages, contacts, group_keys, session_states

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

const _kDbKeyStorageKey = 'ghost_db_encryption_key';
const _kDbFileName      = 'ghost.db';
const _kDbVersion       = 6;

class SecureDb {
  static final SecureDb _instance = SecureDb._();
  factory SecureDb() => _instance;
  SecureDb._();

  Database? _db;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── Open (or create) the encrypted database ───────────────────────────────
  Future<Database> get db async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = await _openDb();
    return _db!;
  }

  Future<Database> _openDb() async {
    final dbDir  = await getApplicationSupportDirectory();
    final dbPath = path.join(dbDir.path, _kDbFileName);
    final dbKey  = await _getOrCreateDbKey();

    return openDatabase(
      dbPath,
      password: dbKey,
      version: _kDbVersion,
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
      singleInstance: true,
    );
  }

  // ── Create schema ─────────────────────────────────────────────────────────
  Future<void> _createSchema(Database db, int version) async {
    final batch = db.batch();

    // Messages (encrypted content stored as ciphertext blobs)
    batch.execute('''
      CREATE TABLE messages (
        id              TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_id       TEXT NOT NULL,
        ciphertext      TEXT NOT NULL,   -- base64 Signal ciphertext
        msg_type        INTEGER NOT NULL, -- 1=prekey, 2=signal, 3=group
        is_read         INTEGER NOT NULL DEFAULT 0,
        is_ephemeral    INTEGER NOT NULL DEFAULT 1,
        ttl_seconds     INTEGER NOT NULL DEFAULT 3600,
        created_at      INTEGER NOT NULL, -- unix timestamp ms
        delete_at       INTEGER,          -- unix timestamp ms; null = read-triggered
        view_once       INTEGER NOT NULL DEFAULT 0,
        status          INTEGER NOT NULL DEFAULT 1,
        decrypt_pending       INTEGER NOT NULL DEFAULT 0,
        decrypt_attempts      INTEGER NOT NULL DEFAULT 0,
        last_decrypt_error    TEXT,
        decrypt_permanent_fail INTEGER NOT NULL DEFAULT 0,
        body_plaintext      TEXT              -- local display only; DB is SQLCipher-encrypted
      )
    ''');

    // Contacts
    batch.execute('''
      CREATE TABLE contacts (
        user_id         TEXT PRIMARY KEY,
        public_key_b64  TEXT NOT NULL,
        nickname        TEXT,             -- local only, never synced
        fingerprint     TEXT NOT NULL,
        verified        INTEGER NOT NULL DEFAULT 0,
        added_at        INTEGER NOT NULL, -- unix timestamp ms
        last_message_at INTEGER,
        chat_ttl_seconds INTEGER NOT NULL DEFAULT 3600
      )
    ''');

    // Group keys — AES-256-GCM group session keys
    batch.execute('''
      CREATE TABLE group_keys (
        group_id        TEXT NOT NULL,
        key_index       INTEGER NOT NULL, -- rotates on membership change
        key_b64         TEXT NOT NULL,    -- base64 AES-256 key
        created_at      INTEGER NOT NULL,
        PRIMARY KEY (group_id, key_index)
      )
    ''');

    // Signal session states (serialized from libsignal)
    batch.execute('''
      CREATE TABLE session_states (
        address         TEXT PRIMARY KEY, -- "userId.deviceId"
        session_b64     TEXT NOT NULL,   -- base64 serialized session record
        updated_at      INTEGER NOT NULL
      )
    ''');

    // Signal prekey material (PRIVATE, stored encrypted by SQLCipher)
    // These records are required to decrypt incoming PreKeySignalMessages.
    batch.execute('''
      CREATE TABLE signal_prekeys (
        key_id          INTEGER PRIMARY KEY,
        record_b64      TEXT NOT NULL,   -- base64 PreKeyRecord.serialize()
        created_at      INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE signal_signed_prekeys (
        key_id          INTEGER PRIMARY KEY,
        record_b64      TEXT NOT NULL,   -- base64 SignedPreKeyRecord.serialize()
        created_at      INTEGER NOT NULL
      )
    ''');

    // Panic codes (PBKDF2 hash only — never stored in plaintext)
    batch.execute('''
      CREATE TABLE panic_config (
        id              INTEGER PRIMARY KEY CHECK (id = 1),
        code_hash_b64   TEXT NOT NULL,  -- PBKDF2-SHA512 hash
        salt_b64        TEXT NOT NULL,
        iterations      INTEGER NOT NULL DEFAULT 600000
      )
    ''');

    await batch.commit(noResult: true);
  }

  /// True if [table] has a column named [column] (for idempotent ALTERs).
  Future<bool> _tableHasColumn(Database db, String table, String column) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    for (final r in rows) {
      if (r['name'] == column) {
        return true;
      }
    }
    return false;
  }

  Future<void> _upgradeSchema(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN status INTEGER NOT NULL DEFAULT 1');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS signal_prekeys (
          key_id          INTEGER PRIMARY KEY,
          record_b64      TEXT NOT NULL,
          created_at      INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS signal_signed_prekeys (
          key_id          INTEGER PRIMARY KEY,
          record_b64      TEXT NOT NULL,
          created_at      INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 4) {
      await db.execute(
          'ALTER TABLE messages ADD COLUMN decrypt_pending INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE messages ADD COLUMN decrypt_attempts INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE messages ADD COLUMN last_decrypt_error TEXT');
      await db.execute(
          'ALTER TABLE messages ADD COLUMN decrypt_permanent_fail INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 5) {
      if (!await _tableHasColumn(db, 'messages', 'body_plaintext')) {
        await db.execute('ALTER TABLE messages ADD COLUMN body_plaintext TEXT');
      }
    }
    if (oldVersion < 6) {
      if (!await _tableHasColumn(db, 'contacts', 'last_message_at')) {
        await db.execute('ALTER TABLE contacts ADD COLUMN last_message_at INTEGER');
      }
      if (!await _tableHasColumn(db, 'contacts', 'chat_ttl_seconds')) {
        await db.execute(
            'ALTER TABLE contacts ADD COLUMN chat_ttl_seconds INTEGER NOT NULL DEFAULT 3600');
      }
    }
  }

  // ── DB key management ─────────────────────────────────────────────────────
  Future<String> _getOrCreateDbKey() async {
    var key = await _secureStorage.read(key: _kDbKeyStorageKey);
    if (key == null) {
      final random    = Random.secure();
      final keyBytes  = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        keyBytes[i] = random.nextInt(256);
      }
      key = base64Encode(keyBytes);
      await _secureStorage.write(key: _kDbKeyStorageKey, value: key);
    }
    return key;
  }

  // ── Messages ──────────────────────────────────────────────────────────────
  Future<void> insertMessage(Map<String, dynamic> msg) async {
    final d = await db;
    await d.insert('messages', msg, conflictAlgorithm: ConflictAlgorithm.replace);
    final cid = msg['conversation_id'];
    final createdAt = msg['created_at'];
    if (cid is String && cid.isNotEmpty && createdAt is int) {
      await touchConversationLastMessageAt(cid, createdAt);
    }
  }

  Future<List<Map<String, dynamic>>> getMessages(String conversationId) async {
    final d = await db;
    return d.query(
      'messages',
      where:   'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at ASC',
    );
  }

  Future<Map<String, dynamic>?> getMessageById(String messageId) async {
    final d = await db;
    final rows = await d.query(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> markMessageRead(String messageId) async {
    final d = await db;
    await d.update(
      'messages',
      {'is_read': 1, 'status': 3},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> markConversationRead(String conversationId) async {
    final d = await db;
    await d.update(
      'messages',
      {'is_read': 1, 'status': 3},
      where: 'conversation_id = ? AND is_read = 0',
      whereArgs: [conversationId],
    );
  }

  Future<Map<String, int>> getUnreadCountsByConversation() async {
    final d = await db;
    final rows = await d.rawQuery('''
      SELECT conversation_id, COUNT(*) as c
      FROM messages
      WHERE is_read = 0
      GROUP BY conversation_id
    ''');
    final out = <String, int>{};
    for (final r in rows) {
      final cid = r['conversation_id'] as String?;
      final c = r['c'];
      if (cid == null) continue;
      out[cid] = (c is int) ? c : int.tryParse('$c') ?? 0;
    }
    return out;
  }

  Future<void> updateMessageStatus(String messageId, int status) async {
    final d = await db;
    await d.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Incoming ciphertext rows awaiting decrypt (excludes own sends and permanent failures).
  Future<List<Map<String, dynamic>>> getPendingDecryptMessages(
    String conversationId,
    String myUserId, {
    int maxAttempts = 50,
  }) async {
    final d = await db;
    return d.query(
      'messages',
      where:
          'conversation_id = ? AND sender_id != ? AND decrypt_pending = 1 AND decrypt_permanent_fail = 0 AND decrypt_attempts < ?',
      whereArgs: [conversationId, myUserId, maxAttempts],
      orderBy: 'created_at ASC',
    );
  }

  Future<void> updateMessageDecryptState(
    String messageId, {
    required int decryptPending,
    required int decryptAttempts,
    String? lastDecryptError,
    required int decryptPermanentFail,
  }) async {
    final d = await db;
    await d.update(
      'messages',
      {
        'decrypt_pending': decryptPending,
        'decrypt_attempts': decryptAttempts,
        'last_decrypt_error': lastDecryptError,
        'decrypt_permanent_fail': decryptPermanentFail,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Persist plaintext for chat list after hot restart (SQLCipher at rest).
  Future<void> updateMessageBodyPlaintext(String messageId, String plaintext) async {
    final d = await db;
    await d.update(
      'messages',
      {'body_plaintext': plaintext},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// After a crypto session auto-reset, ciphertext queued under the old ratchet
  /// will never decrypt — stop retrying and surface as permanent (like WhatsApp
  /// "waiting for this message" timeout behavior).
  Future<int> abandonPendingDecryptsForConversation(
    String conversationId,
    String myUserId, {
    String error = 'session_auto_reset',
  }) async {
    final d = await db;
    return d.update(
      'messages',
      {
        'decrypt_pending': 0,
        'decrypt_permanent_fail': 1,
        'last_decrypt_error': error,
      },
      where:
          'conversation_id = ? AND sender_id != ? AND decrypt_pending = 1',
      whereArgs: [conversationId, myUserId],
    );
  }

  /// True if any conversation still has pending decrypt work.
  Future<bool> hasAnyPendingDecrypt(String myUserId) async {
    final d = await db;
    final rows = await d.rawQuery(
      '''
      SELECT 1 FROM messages
      WHERE sender_id != ? AND decrypt_pending = 1 AND decrypt_permanent_fail = 0
      LIMIT 1
      ''',
      [myUserId],
    );
    return rows.isNotEmpty;
  }

  /// Delete messages whose delete_at timestamp has passed
  Future<int> purgeExpiredMessages() async {
    final d   = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    return d.delete(
      'messages',
      where:     '(is_ephemeral = 1 AND is_read = 1 AND delete_at <= ?) OR '
                 '(ttl_seconds > 0 AND created_at + (ttl_seconds * 1000) <= ?)',
      whereArgs: [now, now],
    );
  }

  // ── Contacts ──────────────────────────────────────────────────────────────
  Future<void> upsertContact(Map<String, dynamic> contact) async {
    final d = await db;
    await d.insert('contacts', contact, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getAllContacts() async {
    final d = await db;
    return d.query(
      'contacts',
      orderBy: 'COALESCE(last_message_at, added_at) DESC, added_at DESC',
    );
  }

  Future<Map<String, dynamic>?> getContact(String userId) async {
    final d    = await db;
    final rows = await d.query('contacts', where: 'user_id = ?', whereArgs: [userId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> deleteContact(String userId) async {
    final d = await db;
    await d.delete('contacts', where: 'user_id = ?', whereArgs: [userId]);
  }

  Future<void> updateContactNickname(String userId, String? nickname) async {
    final d = await db;
    final trimmed = nickname?.trim();
    await d.update(
      'contacts',
      {'nickname': (trimmed == null || trimmed.isEmpty) ? null : trimmed},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  Future<void> touchConversationLastMessageAt(String userId, int timestampMs) async {
    final d = await db;
    await d.update(
      'contacts',
      {'last_message_at': timestampMs},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  Future<void> setChatTtlSeconds(String userId, int ttlSeconds) async {
    final d = await db;
    await d.update(
      'contacts',
      {'chat_ttl_seconds': ttlSeconds},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  // ── Group keys ────────────────────────────────────────────────────────────
  Future<void> storeGroupKey({
    required String groupId,
    required int keyIndex,
    required String keyB64,
  }) async {
    final d   = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await d.insert('group_keys', {
      'group_id':   groupId,
      'key_index':  keyIndex,
      'key_b64':    keyB64,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getLatestGroupKey(String groupId) async {
    final d    = await db;
    final rows = await d.query(
      'group_keys',
      where:     'group_id = ?',
      whereArgs: [groupId],
      orderBy:   'key_index DESC',
      limit:     1,
    );
    return rows.isEmpty ? null : rows.first['key_b64'] as String?;
  }

  // ── Session states ────────────────────────────────────────────────────────
  Future<void> storeSessionState(String address, String sessionB64) async {
    final d = await db;
    await d.insert('session_states', {
      'address':    address,
      'session_b64': sessionB64,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> loadSessionState(String address) async {
    final d    = await db;
    final rows = await d.query('session_states', where: 'address = ?', whereArgs: [address]);
    return rows.isEmpty ? null : rows.first['session_b64'] as String?;
  }

  /// Delete a persisted Signal ratchet session by its store address key.
  /// Address format is expected to match `_persistSession()` in `SignalSessionService`:
  /// `"$contactUserId.$deviceId"`.
  Future<void> deleteSessionState(String address) async {
    final d = await db;
    await d.delete('session_states', where: 'address = ?', whereArgs: [address]);
  }

  // ── Signal prekey material (private) ──────────────────────────────────────
  Future<void> storeSignalPreKeyRecord(int keyId, String recordB64) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await d.insert('signal_prekeys', {
      'key_id': keyId,
      'record_b64': recordB64,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> loadSignalPreKeyRecord(int keyId) async {
    final d = await db;
    final rows = await d.query('signal_prekeys', where: 'key_id = ?', whereArgs: [keyId], limit: 1);
    return rows.isEmpty ? null : rows.first['record_b64'] as String?;
  }

  Future<List<Map<String, dynamic>>> loadAllSignalPreKeyRecords() async {
    final d = await db;
    return d.query('signal_prekeys', orderBy: 'key_id ASC');
  }

  Future<void> deleteSignalPreKeyRecord(int keyId) async {
    final d = await db;
    await d.delete('signal_prekeys', where: 'key_id = ?', whereArgs: [keyId]);
  }

  Future<void> storeSignalSignedPreKeyRecord(int keyId, String recordB64) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await d.insert('signal_signed_prekeys', {
      'key_id': keyId,
      'record_b64': recordB64,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> loadSignalSignedPreKeyRecord(int keyId) async {
    final d = await db;
    final rows = await d.query('signal_signed_prekeys', where: 'key_id = ?', whereArgs: [keyId], limit: 1);
    return rows.isEmpty ? null : rows.first['record_b64'] as String?;
  }

  // ── Panic Wipe ────────────────────────────────────────────────────────────
  /// DoD 5220.22-M inspired: overwrite all rows, then delete DB file.
  Future<void> wipeDatabase() async {
    final d = await db;

    // Overwrite sensitive tables with garbage before deletion
    await d.execute(
        "UPDATE messages SET ciphertext = 'XXXXXXXXXXXXXXXXXXXXXXXX', body_plaintext = NULL");
    await d.execute("UPDATE contacts     SET public_key_b64 = 'XXXX', fingerprint = 'XXXX'");
    await d.execute("UPDATE group_keys   SET key_b64 = 'XXXX'");
    await d.execute("UPDATE session_states SET session_b64 = 'XXXX'");
    await d.execute("UPDATE panic_config  SET code_hash_b64 = 'XXXX', salt_b64 = 'XXXX'");

    // Delete all rows
    await d.execute('DELETE FROM messages');
    await d.execute('DELETE FROM contacts');
    await d.execute('DELETE FROM group_keys');
    await d.execute('DELETE FROM session_states');
    await d.execute('DELETE FROM panic_config');

    await d.close();
    _db = null;

    // Delete the DB file itself
    final dbDir  = await getApplicationSupportDirectory();
    final dbPath = path.join(dbDir.path, _kDbFileName);
    final dbFile = File(dbPath);
    if (await dbFile.exists()) await dbFile.delete();

    // Delete the DB encryption key from secure storage
    const FlutterSecureStorage().delete(key: _kDbKeyStorageKey);
  }
}
