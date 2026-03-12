// Widget test: Add Contact sheet includes "Share my Ghost ID" so user can share QR/link whenever.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_client/features/contacts/contacts_screen.dart';

void main() {
  group('ContactsScreen Add Contact sheet', () {
    testWidgets('FAB opens add sheet with Share my Ghost ID option', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const ContactsScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(FloatingActionButton), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Share my Ghost ID'), findsOneWidget);
    });

    testWidgets('Add Contact sheet has Scan QR and Enter Ghost ID', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const ContactsScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Scan QR Code'), findsOneWidget);
      expect(find.text('Enter Ghost ID'), findsOneWidget);
    });
  });
}
