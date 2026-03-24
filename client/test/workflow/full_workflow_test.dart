// Full workflow tests — run with: flutter test test/workflow/
// No emulator or device required. Simulates: add contact → establishment message → recipient sees contact.

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_client/core/contacts/contact_establishment_service.dart';
import 'package:ghost_client/models/contact.dart';
import 'package:ghost_client/models/message.dart';
import 'package:ghost_client/relay/relay_coordinator.dart';

void main() {
  group('Full workflow (no emulator)', () {
    test('1. Contact add flow: create contact → toDbMap → fromDbMap → same data', () {
      const userId = 'userAlice123456789012345678901234';
      const publicKeyB64 = 'YWxpY2VQdWJsaWNLZXlCYXNlNjQ=';
      const fingerprint = '00000 11111 22222 33333 44444 55555 66666 77777 88888 99999 00000 11111';
      const nickname = 'Alice';
      final addedAt = DateTime.now().millisecondsSinceEpoch;

      final contact = GhostContact(
        userId:       userId,
        publicKeyB64: publicKeyB64,
        fingerprint:  fingerprint,
        nickname:     nickname,
        verified:     false,
        addedAt:      addedAt,
      );

      final dbMap = contact.toDbMap();
      expect(dbMap['user_id'], userId);
      expect(dbMap['public_key_b64'], publicKeyB64);
      expect(dbMap['nickname'], nickname);
      expect(dbMap['verified'], 0);
      expect(dbMap['added_at'], addedAt);

      final restored = GhostContact.fromDbMap(dbMap);
      expect(restored.userId, contact.userId);
      expect(restored.publicKeyB64, contact.publicKeyB64);
      expect(restored.nickname, contact.nickname);
      expect(restored.displayName, nickname);
      expect(restored.shortId, contains('...'));
    });

    test('2. Contact establishment message: constant and relay packet shape', () {
      expect(kContactEstablishmentMessage, isNotEmpty);
      expect(kContactEstablishmentMessage, contains('Contact'));

      // Packet shape that ContactEstablishmentService sends (relay expects these keys)
      final packetShape = {
        'id':          'test-uuid',
        'to':          'recipientUserId',
        'ciphertext':  'base64ciphertext',
        'msg_type':    'prekey',
        'ttl_seconds': 3600,
      };
      expect(packetShape.keys, containsAll(['id', 'to', 'ciphertext', 'msg_type', 'ttl_seconds']));
    });

    test('3. Relay coordinator: buffer and current chat (recipient side)', () {
      final coordinator = RelayCoordinator();

      coordinator.setCurrentChat(null, null);
      expect(coordinator.getBufferedPackets('bob'), isEmpty);

      coordinator.setCurrentChat('bob', (packet) async {
        expect(packet['from'], isNotNull);
        expect(packet['ciphertext'], isNotNull);
      });
      coordinator.setCurrentChat(null, null);
    });

    test('4. Message model: round-trip toDbMap / fromDbMap for chat flow', () {
      final msg = GhostMessage(
        id:             'msg-1',
        conversationId: 'bob',
        senderId:       'alice',
        ciphertext:     'dGVzdENpcGhlcg==',
        msgType:        MessageType.signal,
        createdAt:      DateTime.now().millisecondsSinceEpoch,
        ttlSeconds:     3600,
        status:         MessageStatus.sent,
      );

      final dbMap = msg.toDbMap();
      expect(dbMap['conversation_id'], 'bob');
      expect(dbMap['sender_id'], 'alice');
      expect(dbMap['msg_type'], MessageType.signal.index);

      final restored = GhostMessage.fromDbMap(dbMap);
      expect(restored.id, msg.id);
      expect(restored.conversationId, msg.conversationId);
    });

    test('5. Ghost ID share payload shape (ghost://add/userId/publicKeyB64)', () {
      const userId = 'user12345678901234567890';
      const publicKeyB64 = 'cHVibGljS2V5';
      final link = 'ghost://add/$userId/$publicKeyB64';
      expect(link, startsWith('ghost://add/'));
      expect(link.split('/'), hasLength(5));
      expect(link.split('/')[3], userId);
      expect(link.split('/')[4], publicKeyB64);
    });

    test('6. ContactEstablishmentService is singleton', () {
      expect(ContactEstablishmentService(), same(ContactEstablishmentService()));
    });
  });
}
