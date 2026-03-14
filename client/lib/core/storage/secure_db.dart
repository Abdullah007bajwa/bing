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
const _kDbVersion       = 2;

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
        status          INTEGER NOT NULL DEFAULT 1
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
        added_at        INTEGER NOT NULL  -- unix timestamp ms
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

  Future<void> _upgradeSchema(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN status INTEGER NOT NULL DEFAULT 1');
    }
  }

  // ── DB key management ─────────────────────────────────────────────────────
  Future<String> _getOrCreateDbKey() async {
    var key = await _secureStorage.read(key: _kDbKeyStorageKey);
    if (key == null) {
      final random    = Random.secure();
      final keyBytes  = Uint8List(32);
      for (var i = 0; i < 32; i++) keyBytes[i] = random.nextInt(256);
      key = base64Encode(keyBytes);
      await _secureStorage.write(key: _kDbKeyStorageKey, value: key);
    }
    return key;
  }

  // ── Messages ──────────────────────────────────────────────────────────────
  Future<void> insertMessage(Map<String, dynamic> msg) async {
    final d = await db;
    await d.insert('messages', msg, conflictAlgorithm: ConflictAlgorithm.replace);
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

  Future<void> markMessageRead(String messageId) async {
    final d = await db;
    await d.update(
      'messages',
      {'is_read': 1, 'delete_at': DateTime.now().millisecondsSinceEpoch + 5000, 'status': 3},
      where: 'id = ?',
      whereArgs: [messageId],
    );
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
    return d.query('contacts', orderBy: 'added_at DESC');
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

  // ── Panic Wipe ────────────────────────────────────────────────────────────
  /// DoD 5220.22-M inspired: overwrite all rows, then delete DB file.
  Future<void> wipeDatabase() async {
    final d = await db;

    // Overwrite sensitive tables with garbage before deletion
    await d.execute("UPDATE messages     SET ciphertext = 'XXXXXXXXXXXXXXXXXXXXXXXX'");
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
