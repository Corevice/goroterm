import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/storage/database.dart';
import 'package:terminal_ssh_app/features/connections/connection_list_screen.dart';
import 'package:terminal_ssh_app/features/connections/connection_provider.dart';

import '../../test_localizations.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeEmpty extends ConnectionListNotifier {
  @override
  Future<List<Connection>> build() async => [];
}

class _FakeWithConnections extends ConnectionListNotifier {
  @override
  Future<List<Connection>> build() async => [
        Connection(
          id: 1,
          label: 'My Server',
          host: 'example.com',
          port: 22,
          username: 'admin',
          authMethod: 'password',
          createdAt: DateTime(2024),
        ),
        Connection(
          id: 2,
          label: '',
          host: '192.168.1.100',
          port: 2222,
          username: 'root',
          authMethod: 'key',
          createdAt: DateTime(2024),
        ),
      ];

  @override
  Future<void> deleteConnection(int id) async {}
}

Widget _buildApp({required Widget home}) {
  return localizedTestApp(home: home);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ConnectionListScreen', () {
    testWidgets('shows empty state when no connections', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionListProvider.overrideWith(_FakeEmpty.new),
          ],
          child: _buildApp(home: const ConnectionListScreen()),
        ),
      );
      await tester.pump();

      expect(find.text('No connections yet'), findsOneWidget);
      expect(find.text('Tap + to add a new SSH connection'), findsOneWidget);
    });

    testWidgets('shows list with connections', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionListProvider.overrideWith(_FakeWithConnections.new),
          ],
          child: _buildApp(home: const ConnectionListScreen()),
        ),
      );
      await tester.pump();

      expect(find.text('My Server'), findsOneWidget);
      // Second connection has no label - should show host
      expect(find.text('192.168.1.100'), findsOneWidget);
    });

    testWidgets('shows subtitle with user@host:port', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionListProvider.overrideWith(_FakeWithConnections.new),
          ],
          child: _buildApp(home: const ConnectionListScreen()),
        ),
      );
      await tester.pump();

      expect(find.text('admin@example.com:22'), findsOneWidget);
      expect(find.text('root@192.168.1.100:2222'), findsOneWidget);
    });

    testWidgets('FAB is present', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionListProvider.overrideWith(_FakeEmpty.new),
          ],
          child: _buildApp(home: const ConnectionListScreen()),
        ),
      );
      await tester.pump();

      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('shows app bar title', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionListProvider.overrideWith(_FakeEmpty.new),
          ],
          child: _buildApp(home: const ConnectionListScreen()),
        ),
      );
      await tester.pump();

      expect(find.text('SSH Connections'), findsOneWidget);
    });

    testWidgets('long press shows bottom sheet with edit and delete',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionListProvider.overrideWith(_FakeWithConnections.new),
          ],
          child: _buildApp(home: const ConnectionListScreen()),
        ),
      );
      await tester.pump();

      await tester.longPress(find.text('My Server'));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('shows loading indicator while fetching', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionListProvider.overrideWith(_FakeEmpty.new),
          ],
          child: _buildApp(home: const ConnectionListScreen()),
        ),
      );
      // Before pump: loading state
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
