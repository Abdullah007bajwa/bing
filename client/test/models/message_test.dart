import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_client/models/message.dart';

void main() {
  group('GhostMessage Tests', () {
    test('should properly serialize to and from DB map', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      
      final msg = GhostMessage(
        id: 'msg-abc',
        conversationId: 'conv-xyz',
        senderId: 'user-1',
        ciphertext: 'base64encodedblob==',
        msgType: MessageType.signal,
        createdAt: now,
        ttlSeconds: 3600,
        viewOnce: false,
        status: MessageStatus.delivered,
      );

      final map = msg.toDbMap();
      
      expect(map['id'], equals('msg-abc'));
      expect(map['conversation_id'], equals('conv-xyz'));
      expect(map['sender_id'], equals('user-1'));
      expect(map['ciphertext'], equals('base64encodedblob=='));
      expect(map['msg_type'], equals(MessageType.signal.index)); // enum mapped as index
      expect(map['created_at'], equals(now));
      expect(map['ttl_seconds'], equals(3600));
      expect(map['view_once'], equals(0));      // bool mapped to int
      expect(map['is_ephemeral'], equals(1));   // bool mapped to int
      expect(map['is_read'], equals(0));        // bool mapped to int
      // Note: 'status' is a UI/local field, not persisted in the DB map

      // Add dummy status field just so fromDbMap doesn't throw if we relied on it, though we don't
      final restored = GhostMessage.fromDbMap(map);
      
      expect(restored.id, equals(msg.id));
      expect(restored.conversationId, equals(msg.conversationId));
      expect(restored.ciphertext, equals(msg.ciphertext));
      expect(restored.ttlSeconds, equals(msg.ttlSeconds));
      expect(restored.msgType, equals(MessageType.signal));
      expect(restored.isEphemeral, isTrue);
    });

    test('isEphemeral logic should be correct', () {
      final ephemeralMsg = GhostMessage(
        id: '1',
        conversationId: '2',
        senderId: '3',
        ciphertext: 'txt',
        msgType: MessageType.signal,
        createdAt: 0,
        ttlSeconds: 3600,
        status: MessageStatus.sent,
      );

      final permanentMsg = GhostMessage(
        id: '1',
        conversationId: '2',
        senderId: '3',
        ciphertext: 'txt',
        msgType: MessageType.signal,
        createdAt: 0,
        ttlSeconds: 0,
        isEphemeral: false,
        status: MessageStatus.sent,
      );

      expect(ephemeralMsg.isEphemeral, isTrue);
      expect(permanentMsg.isEphemeral, isFalse);
    });
  });
}
