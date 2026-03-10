// ignore_for_file: avoid_print

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:terminal_ssh_app/app.dart';
import 'package:terminal_ssh_app/core/storage/database.dart';
import 'package:terminal_ssh_app/features/connections/connection_provider.dart';

/// Minimal integration test: app starts, connection list screen appears,
/// user can navigate to "New Connection" screen.
///
/// Note: No real SSH server is used. The test verifies the navigation
/// flow and basic UI rendering using an in-memory database.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App integration', () {
    testWidgets('app starts and shows connection list', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
          ],
          child: const TerminalSshApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Connection list screen is shown
      expect(find.text('SSH Connections'), findsOneWidget);
    });

    testWidgets('FAB tap navigates to new connection screen', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
          ],
          child: const TerminalSshApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Tap the FAB
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Should navigate to new connection screen
      expect(find.text('New Connection'), findsOneWidget);
    });

    testWidgets('new connection form shows required fields', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
          ],
          child: const TerminalSshApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // All required fields are present
      expect(find.text('Host *'), findsOneWidget);
      expect(find.text('Username *'), findsOneWidget);
      expect(find.text('Port'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('can add a connection and see it in the list', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
          ],
          child: const TerminalSshApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Navigate to new connection
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Fill in form
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Label'),
        'Test Server',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host *'),
        'example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username *'),
        'admin',
      );

      // Save
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Back on connection list, new connection shown
      expect(find.text('Test Server'), findsOneWidget);
      expect(find.text('admin@example.com:22'), findsOneWidget);
    });
  });
}
