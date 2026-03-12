// Tests for RelayCoordinator buffer and current-chat API.

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_client/relay/relay_coordinator.dart';

void main() {
  group('RelayCoordinator', () {
    test('getBufferedPackets returns empty list for unknown contact', () {
      final coordinator = RelayCoordinator();
      final packets = coordinator.getBufferedPackets('unknownUserId');
      expect(packets, isEmpty);
    });

    test('getBufferedPackets returns empty on second call for same id (buffer cleared)', () {
      final coordinator = RelayCoordinator();
      coordinator.getBufferedPackets('someId');
      final again = coordinator.getBufferedPackets('someId');
      expect(again, isEmpty);
    });

    test('setCurrentChat with null does not throw', () {
      final coordinator = RelayCoordinator();
      expect(() => coordinator.setCurrentChat(null, null), returnsNormally);
    });

    test('setCurrentChat with callback does not throw', () {
      final coordinator = RelayCoordinator();
      expect(
        () => coordinator.setCurrentChat('user1', (_) {}),
        returnsNormally,
      );
      coordinator.setCurrentChat(null, null);
    });

    test('relay getter returns non-null client', () {
      final coordinator = RelayCoordinator();
      expect(coordinator.relay, isNotNull);
    });
  });
}
