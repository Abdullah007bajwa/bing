// lib/features/groups/group_service.dart
// Client-managed encrypted groups (Megolm-inspired).
// Server never sees group membership or group keys.
// Group key rotates on every membership change.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import '../../core/storage/secure_db.dart';
import '../../core/crypto/signal_session.dart';
import '../../relay/websocket_client.dart';

class GroupService {
  static final GroupService _instance = GroupService._();
  factory GroupService() => _instance;
  GroupService._();

  final _db      = SecureDb();
  final _relay   = GhostRelayClient();
  final _aes     = AesCbc.with256bits(macAlgorithm: Hmac.sha256());
  final _uuid    = const Uuid();
  final _random  = Random.secure();

  // ── Create a new group ────────────────────────────────────────────────────
  Future<String> createGroup({
    required String creatorUserId,
    required List<String> memberUserIds,
    required SignalSessionService signalSession,
    required dynamic signalStore,
  }) async {
    final groupId = _uuid.v4();
    final groupKey = _generateGroupKey();
    final keyB64   = base64Encode(groupKey);

    // Store our own copy
    await _db.storeGroupKey(groupId: groupId, keyIndex: 0, keyB64: keyB64);

    // Encrypt group key individually for each member via their Signal session
    for (final memberId in memberUserIds) {
      final contact = await _db.getContact(memberId);
      if (contact == null) continue;

      final cipher = await signalSession.getOrCreateSession(
        contactUserId:      memberId,
        contactPublicKeyB64: contact['public_key_b64'] as String,
        store:              signalStore,
        deviceId:           1,
      );

      final encKeyPacket = await signalSession.encryptMessage(
        cipher:    cipher,
        plaintext: jsonEncode({
          'type':      'group_invite',
          'group_id':  groupId,
          'group_key': keyB64,
          'key_index': 0,
          'members':   memberUserIds,
        }),
      );

      _relay.sendPacket({
        'to':          memberId,
        'ciphertext':  encKeyPacket['ciphertext'],
        'msg_type':    'key_exchange',
        'ttl_seconds': 86400,
      });
    }

    return groupId;
  }

  // ── Encrypt a group message ────────────────────────────────────────────────
  Future<String> encryptGroupMessage({
    required String groupId,
    required String plaintext,
  }) async {
    final keyB64 = await _db.getLatestGroupKey(groupId);
    if (keyB64 == null) throw StateError('No group key for $groupId');

    final keyBytes  = base64Decode(keyB64);
    final secretKey = await _aes.newSecretKeyFromBytes(keyBytes);
    final nonce     = _generateNonce();

    final secretBox = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey:  secretKey,
      nonce:      nonce,
    );

    // Packet: base64(nonce + mac + ciphertext)
    final combined = Uint8List.fromList([
      ...nonce,
      ...secretBox.mac.bytes,
      ...secretBox.cipherText,
    ]);
    return base64Encode(combined);
  }

  // ── Decrypt a group message ────────────────────────────────────────────────
  Future<String> decryptGroupMessage({
    required String groupId,
    required int keyIndex,
    required String ciphertextB64,
  }) async {
    final rows = await _db.db.then((d) => d.query(
      'group_keys',
      where:     'group_id = ? AND key_index = ?',
      whereArgs: [groupId, keyIndex],
    ));
    if (rows.isEmpty) throw StateError('No group key for index $keyIndex');

    final keyBytes  = base64Decode(rows.first['key_b64'] as String);
    final secretKey = await _aes.newSecretKeyFromBytes(keyBytes);
    final combined  = base64Decode(ciphertextB64);

    // Extract: first 16 = nonce, next 32 = mac, rest = ciphertext
    final nonce      = combined.sublist(0, 16);
    final macBytes   = combined.sublist(16, 48);
    final cipherText = combined.sublist(48);

    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
    final plaintext = await _aes.decrypt(secretBox, secretKey: secretKey);
    return utf8.decode(plaintext);
  }

  // ── Rotate group key (on member add/leave) ────────────────────────────────
  Future<void> rotateGroupKey({
    required String groupId,
    required List<String> currentMembers,
    required SignalSessionService signalSession,
    required dynamic signalStore,
  }) async {
    // Get current key index
    final rows = await _db.db.then((d) => d.query(
      'group_keys',
      where:   'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'key_index DESC',
      limit:   1,
    ));
    final newIndex = rows.isEmpty ? 0 : (rows.first['key_index'] as int) + 1;

    final newKey  = _generateGroupKey();
    final keyB64  = base64Encode(newKey);
    await _db.storeGroupKey(groupId: groupId, keyIndex: newIndex, keyB64: keyB64);

    // Re-distribute to remaining members only
    for (final memberId in currentMembers) {
      final contact = await _db.getContact(memberId);
      if (contact == null) continue;

      final cipher = await signalSession.getOrCreateSession(
        contactUserId:      memberId,
        contactPublicKeyB64: contact['public_key_b64'] as String,
        store:              signalStore,
        deviceId:           1,
      );

      final encKeyPacket = await signalSession.encryptMessage(
        cipher:    cipher,
        plaintext: jsonEncode({
          'type':      'group_key_rotation',
          'group_id':  groupId,
          'group_key': keyB64,
          'key_index': newIndex,
        }),
      );

      _relay.sendPacket({
        'to':          memberId,
        'ciphertext':  encKeyPacket['ciphertext'],
        'msg_type':    'key_exchange',
        'ttl_seconds': 86400,
      });
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  Uint8List _generateGroupKey() {
    final key = Uint8List(32); // 256 bits
    for (var i = 0; i < 32; i++) key[i] = _random.nextInt(256);
    return key;
  }

  List<int> _generateNonce() {
    final nonce = List<int>.generate(16, (_) => _random.nextInt(256));
    return nonce;
  }
}
