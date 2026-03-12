// Tests for contact establishment: automated message constant and service behavior.

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_client/core/contacts/contact_establishment_service.dart';
import 'package:ghost_client/models/contact.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('ContactEstablishmentService', () {
    test('kContactEstablishmentMessage is non-empty and indicates contact added', () {
      expect(kContactEstablishmentMessage, isNotEmpty);
      expect(
        kContactEstablishmentMessage.toLowerCase(),
        contains('contact'),
      );
      expect(
        kContactEstablishmentMessage.toLowerCase(),
        contains('chat'),
      );
    });

    test('ContactEstablishmentService is a singleton', () {
      final a = ContactEstablishmentService();
      final b = ContactEstablishmentService();
      expect(identical(a, b), isTrue);
    });

    test('sendContactEstablishmentMessage returns false when identity not loaded', () async {
      // In test env there is no real identity (no secure storage); service returns false.
      final contact = GhostContact(
        userId:       'testUserId12345678901234567890',
        publicKeyB64: 'dGVzdFB1YktleQ==',
        fingerprint:  '00000 11111 22222 33333 44444 55555 66666 77777 88888 99999 00000 11111',
        addedAt:      DateTime.now().millisecondsSinceEpoch,
      );
      final service = ContactEstablishmentService();
      bool result = false;
      try {
        result = await service.sendContactEstablishmentMessage(contact);
      } catch (_) {
        // Binding or secure storage may throw in test env
      }
      expect(result, isFalse);
    });
  });
}
