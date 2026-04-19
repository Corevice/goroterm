import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:terminal_ssh_app/core/storage/connection_repository.dart';
import 'package:terminal_ssh_app/core/storage/database.dart';
import 'package:terminal_ssh_app/core/storage/secure_storage.dart';
import 'package:terminal_ssh_app/features/connections/connection_edit_screen.dart';
import 'package:terminal_ssh_app/features/connections/connection_provider.dart';

import '../../test_localizations.dart';

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

class MockConnectionRepository extends Mock implements ConnectionRepository {}

class MockSecureStorageService extends Mock implements SecureStorageService {}

class _FakeConnectionListNotifier extends ConnectionListNotifier {
  @override
  Future<List<Connection>> build() async => [];

  @override
  Future<int> addConnection({
    required String label,
    required String host,
    required int port,
    required String username,
    required String authMethod,
    String? password,
    String? privateKeyPem,
  }) async =>
      99;

  @override
  Future<void> updateConnection({
    required int id,
    required String label,
    required String host,
    required int port,
    required String username,
    required String authMethod,
    String? password,
    String? privateKeyPem,
  }) async {}
}

// ---------------------------------------------------------------------------
// Helper to wrap with ProviderScope (new connection mode, no mocks needed)
// ---------------------------------------------------------------------------

Widget _buildNew() {
  return ProviderScope(
    overrides: [
      connectionListProvider.overrideWith(_FakeConnectionListNotifier.new),
    ],
    child: localizedTestApp(home: const ConnectionEditScreen()),
  );
}

Widget _buildEdit({
  required MockConnectionRepository mockRepo,
  required MockSecureStorageService mockStorage,
}) {
  return ProviderScope(
    overrides: [
      connectionRepositoryProvider.overrideWith((ref) => mockRepo),
      secureStorageProvider.overrideWith((ref) => mockStorage),
      connectionListProvider.overrideWith(_FakeConnectionListNotifier.new),
    ],
    child: localizedTestApp(home: const ConnectionEditScreen(connectionId: 1)),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ConnectionEditScreen - new connection', () {
    testWidgets('shows "New Connection" title', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();
      expect(find.text('New Connection'), findsOneWidget);
    });

    testWidgets('shows required field labels', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();
      expect(find.text('Host *'), findsOneWidget);
      expect(find.text('Username *'), findsOneWidget);
      expect(find.text('Port'), findsOneWidget);
    });

    testWidgets('shows Save button', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('shows authentication dropdown', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();
      expect(find.text('Authentication'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    });

    testWidgets('validates host is required on Save tap', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();

      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(find.text('Host is required'), findsOneWidget);
    });

    testWidgets('validates username is required', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();

      // Fill host, leave username empty
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host *'),
        'example.com',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(find.text('Username is required'), findsOneWidget);
    });

    testWidgets('validates port range', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Port'),
        '99999',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(find.text('Invalid port (1-65535)'), findsOneWidget);
    });

    testWidgets('no validation error when all required fields filled',
        (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host *'),
        'example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username *'),
        'user',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(find.text('Host is required'), findsNothing);
      expect(find.text('Username is required'), findsNothing);
    });
  });

  group('ConnectionEditScreen - SSH key auth', () {
    testWidgets('PEM field not visible when Password auth is selected',
        (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();

      // Default is 'password', so PEM field should not appear
      expect(find.text('Private Key (PEM)'), findsNothing);
    });

    testWidgets('switching to SSH Key reveals PEM field', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();

      // Open dropdown and select SSH Key
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH Key').last);
      await tester.pumpAndSettle();

      expect(find.text('Private Key (PEM)'), findsOneWidget);
    });

    testWidgets('switching to SSH Key reveals Passphrase field', (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH Key').last);
      await tester.pumpAndSettle();

      // Passphrase field may be off-screen in a scrollable list
      expect(
        find.text('Passphrase (optional)', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('switching to SSH Key reveals Load from file button',
        (tester) async {
      await tester.pumpWidget(_buildNew());
      await tester.pump();

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH Key').last);
      await tester.pumpAndSettle();

      // Button may be off-screen in a scrollable list
      expect(
        find.text('Load from file', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('PEM validation shows error when BEGIN/END markers missing',
        (tester) async {
      // Use a tall surface so the Save button is always visible in the list
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_buildNew());
      await tester.pump();

      // Switch to SSH Key
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH Key').last);
      await tester.pumpAndSettle();

      // Fill required fields so overall form can validate
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host *'),
        'example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username *'),
        'user',
      );

      // Enter invalid PEM (no BEGIN/END markers)
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private Key (PEM)'),
        'not-a-valid-pem',
      );

      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(find.text('Invalid PEM format'), findsOneWidget);
    });
  });

  group('ConnectionEditScreen - edit mode', () {
    late MockConnectionRepository mockRepo;
    late MockSecureStorageService mockStorage;

    setUp(() {
      mockRepo = MockConnectionRepository();
      mockStorage = MockSecureStorageService();

      when(() => mockRepo.getById(1)).thenAnswer(
        (_) async => Connection(
          id: 1,
          label: 'Test',
          host: 'test.com',
          port: 22,
          username: 'user',
          authMethod: 'password',
          createdAt: DateTime(2024),
        ),
      );
      when(() => mockStorage.loadPassword(1)).thenAnswer((_) async => null);
      when(() => mockStorage.loadPrivateKey(1)).thenAnswer((_) async => null);
      when(() => mockStorage.loadPassphrase(1)).thenAnswer((_) async => null);
    });

    testWidgets('shows "Edit Connection" title', (tester) async {
      await tester.pumpWidget(
        _buildEdit(mockRepo: mockRepo, mockStorage: mockStorage),
      );
      await tester.pump();

      expect(find.text('Edit Connection'), findsOneWidget);
    });

    testWidgets('shows Update button', (tester) async {
      await tester.pumpWidget(
        _buildEdit(mockRepo: mockRepo, mockStorage: mockStorage),
      );
      await tester.pump();

      expect(find.text('Update'), findsOneWidget);
    });

    testWidgets('pre-populates fields after async load', (tester) async {
      await tester.pumpWidget(
        _buildEdit(mockRepo: mockRepo, mockStorage: mockStorage),
      );
      await tester.pumpAndSettle();

      // After load completes, host and username should be filled
      expect(find.text('test.com'), findsOneWidget);
      expect(find.text('user'), findsOneWidget);
    });
  });
}
