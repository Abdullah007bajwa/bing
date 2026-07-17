// Widget tests for ContactConfirmScreen: Add Contact flow and nickname.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_client/features/contacts/contact_confirm_screen.dart';

void main() {
  group('ContactConfirmScreen', () {
    const testUserId = 'testUser123456789012345678901234';
    const testPublicKeyB64 = 'dGVzdFB1YktleUJhc2U2NA==';
    const testFingerprint = '00000 11111 22222 33333 44444 55555 66666 77777 88888 99999 00000 11111';

    testWidgets('shows Add Contact button', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const ContactConfirmScreen(
            userId:       testUserId,
            publicKeyB64: testPublicKeyB64,
            fingerprint:  testFingerprint,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Add Contact'), findsWidgets);
    });

    testWidgets('shows nickname field with hint', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const ContactConfirmScreen(
            userId:       testUserId,
            publicKeyB64: testPublicKeyB64,
            fingerprint:  testFingerprint,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('shows Vexa ID and Confirm contact text', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const ContactConfirmScreen(
            userId:       testUserId,
            publicKeyB64: testPublicKeyB64,
            fingerprint:  testFingerprint,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Vexa ID'), findsOneWidget);
      expect(find.text('Confirm contact'), findsOneWidget);
    });

    testWidgets('Cancel button is present', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const ContactConfirmScreen(
            userId:       testUserId,
            publicKeyB64: testPublicKeyB64,
            fingerprint:  testFingerprint,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
    });
  });
}
