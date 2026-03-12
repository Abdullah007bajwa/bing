// Widget tests for GhostIdScreen: QR, Copy, Share available whenever.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_client/features/settings/ghost_id_screen.dart';

void main() {
  group('GhostIdScreen', () {
    testWidgets('shows loading when identity not yet loaded', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const GhostIdScreen(),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('has app bar title Ghost ID', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const GhostIdScreen(),
        ),
      );
      await tester.pump();

      expect(find.text('Ghost ID'), findsWidgets);
    });
  });
}
