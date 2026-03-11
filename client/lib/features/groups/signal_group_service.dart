// lib/features/groups/signal_group_service.dart
// Group messaging using Signal Protocol Double Ratchet for N-way encryption.
// Since libsignal_protocol_dart doesn't support native SenderKey yet, we use
// individual 1:1 sessions to each group member (fan-out encryption).
// Future: Replace with true SenderKey when library support is added.

import 'dart:convert';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../core/storage/secure_db.dart';
import '../../core/crypto/signal_session.dart';
import '../../relay/websocket_client.dart';

class SignalGroupService {
  static final SignalGroupService _instance = SignalGroupService._();
  factory SignalGroupService() => _instance;
  SignalGroupService._();

  final _relay = GhostRelayClient();
  final _db = SecureDb();

  /// Encrypt a group message by encrypting to each member individually (fan-out)
  /// This is the fallback approach until SenderKey is supported
  Future<Map<String, dynamic>> encryptGroupMessage({
    required String groupId,
    required String plaintext,
    required List<String> memberUserIds,
    required InMemorySignalProtocolStore signalStore,
    required SignalSessionService signalSession,
  }) async {
    final encryptedPayloads = <String, Map<String, dynamic>>{};

    for (final memberId in memberUserIds) {
      final contact = await _db.getContact(memberId);
      if (contact == null) continue;

      final cipher = await signalSession.getOrCreateSession(
        contactUserId: memberId,
        contactPublicKeyB64: contact['public_key_b64'] as String,
        store: signalStore,
        deviceId: 1,
      );

      final encPayload = await signalSession.encryptMessage(
        cipher: cipher,
        plaintext: plaintext,
      );

      encryptedPayloads[memberId] = encPayload;
    }

    return encryptedPayloads;
  }

  /// Decrypt a group message using the sender's 1:1 session
  Future<String> decryptGroupMessage({
    required String senderUserId,
    required Map<String, dynamic> encryptedPayload,
    required InMemorySignalProtocolStore signalStore,
    required SignalSessionService signalSession,
  }) async {
    final contact = await _db.getContact(senderUserId);
    if (contact == null) throw Exception('Unknown sender: $senderUserId');

    final cipher = await signalSession.getOrCreateSession(
      contactUserId: senderUserId,
      contactPublicKeyB64: contact['public_key_b64'] as String,
      store: signalStore,
      deviceId: 1,
    );

    final plaintext = await signalSession.decryptMessage(
      cipher: cipher,
      packet: encryptedPayload,
    );

    return plaintext;
  }

  /// Broadcast encrypted group message to all members
  Future<void> sendGroupMessage({
    required String groupId,
    required String plaintext,
    required List<String> memberUserIds,
    required InMemorySignalProtocolStore signalStore,
    required SignalSessionService signalSession,
  }) async {
    final encryptedPayloads = await encryptGroupMessage(
      groupId: groupId,
      plaintext: plaintext,
      memberUserIds: memberUserIds,
      signalStore: signalStore,
      signalSession: signalSession,
    );

    for (final entry in encryptedPayloads.entries) {
      _relay.sendPacket({
        'to': entry.key,
        'ciphertext': entry.value['ciphertext'],
        'type': entry.value['type'],
        'msg_type': 'group_message',
        'group_id': groupId,
        'ttl_seconds': 86400,
      });
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// FUTURE: Native SenderKey implementation (when libsignal_protocol_dart adds support)
// ══════════════════════════════════════════════════════════════════════════════
/*
/// Step 1: User generates their own SenderKey for a specific Group UUID
Future<SenderKeyDistributionMessage> createSenderKeyForGroup({
  required String groupId,
  required String myUserId,
  required InMemorySenderKeyStore senderKeyStore,
}) async {
  final senderKeyName = SenderKeyName(groupId, SignalProtocolAddress(myUserId, 1));
  final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
  final distributionMessage = await groupSessionBuilder.create(senderKeyName);
  return distributionMessage;
}

/// Step 2: Distribute the SenderKey to other group members over 1:1 chats
Future<void> distributeSenderKey({
  required List<String> memberUserIds,
  required SenderKeyDistributionMessage skdm,
  required String groupId,
  required SignalSessionService signalSession,
  required dynamic signalStore,
}) async {
  final serializedSkdm = base64Encode(skdm.serialize());
  for (final memberId in memberUserIds) {
    final contact = await _db.getContact(memberId);
    if (contact == null) continue;

    final cipher = await signalSession.getOrCreateSession(
      contactUserId: memberId,
      contactPublicKeyB64: contact['public_key_b64'] as String,
      store: signalStore,
      deviceId: 1,
    );

    final encPayload = await signalSession.encryptMessage(
      cipher: cipher,
      plaintext: jsonEncode({
        'type': 'sender_key_dist',
        'group_id': groupId,
        'skdm': serializedSkdm,
      }),
    );

    _relay.sendPacket({
      'to': memberId,
      'ciphertext': encPayload['ciphertext'],
      'msg_type': 'group_key_exchange',
      'ttl_seconds': 86400,
    });
  }
}

/// Step 3: Process received SenderKey
Future<void> processReceivedSenderKey({
  required String senderUserId,
  required String groupId,
  required String skdmB64,
  required InMemorySenderKeyStore senderKeyStore,
}) async {
  final skdmBytes = base64Decode(skdmB64);
  final skdm = SenderKeyDistributionMessage.fromSerialized(skdmBytes);
  final senderKeyName = SenderKeyName(groupId, SignalProtocolAddress(senderUserId, 1));
  final groupSessionBuilder = GroupSessionBuilder(senderKeyStore);
  groupSessionBuilder.process(senderKeyName, skdm);
}

/// Step 4: Encrypt group message with SenderKey
Future<String> encryptGroupMessageWithSenderKey({
  required String groupId,
  required String myUserId,
  required String plaintext,
  required InMemorySenderKeyStore senderKeyStore,
}) async {
  final senderKeyName = SenderKeyName(groupId, SignalProtocolAddress(myUserId, 1));
  final groupCipher = GroupCipher(senderKeyStore, senderKeyName);
  final ciphertextMessage = await groupCipher.encrypt(utf8.encode(plaintext));
  return base64Encode(ciphertextMessage);
}

/// Step 5: Decrypt group message with SenderKey
Future<String> decryptGroupMessageWithSenderKey({
  required String groupId,
  required String senderUserId,
  required String ciphertextB64,
  required InMemorySenderKeyStore senderKeyStore,
}) async {
  final senderKeyName = SenderKeyName(groupId, SignalProtocolAddress(senderUserId, 1));
  final groupCipher = GroupCipher(senderKeyStore, senderKeyName);
  final ciphertextBytes = base64Decode(ciphertextB64);
  final plaintextBytes = await groupCipher.decrypt(ciphertextBytes);
  return utf8.decode(plaintextBytes);
}
*/
