import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_client/core/storage/ephemeral_cache.dart';

void main() {
  group('EphemeralCache Tests', () {
    late EphemeralCache cache;

    setUp(() {
      cache = EphemeralCache();
      cache.clear();
    });

    test('should store and retrieve plaintext message', () {
      const msgId = 'msg-123';
      const text = 'Top secret message';

      cache.cacheMessage(msgId, text, ttl: const Duration(hours: 1));

      final retrieved = cache.getMessage(msgId);
      expect(retrieved, equals(text));
    });

    test('should clear all cached messages', () {
      cache.cacheMessage('msg-1', 'text 1');
      cache.cacheMessage('msg-2', 'text 2');

      cache.clear();

      expect(cache.getMessage('msg-1'), isNull);
      expect(cache.getMessage('msg-2'), isNull);
    });

    test('should auto-expire items after TTL', () async {
      const msgId = 'msg-expire-1';
      cache.cacheMessage(msgId, 'will expire fast', ttl: const Duration(milliseconds: 100));

      // Immediate fetch should work
      expect(cache.getMessage(msgId), isNotNull);

      // Wait for expiration
      await Future.delayed(const Duration(milliseconds: 150));

      // Fetch after TTL should return null
      expect(cache.getMessage(msgId), isNull);
    });

    test('multiple instantiations should return the same singleton instance', () {
      final cache2 = EphemeralCache();
      cache.cacheMessage('test', 'value');

      expect(cache2.getMessage('test'), equals('value'));
      expect(identical(cache, cache2), isTrue);
    });
  });
}
