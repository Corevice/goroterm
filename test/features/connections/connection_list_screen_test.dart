// Merged from: connection_list_screen_test.dart, connection_provider_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:terminal_ssh_app/core/storage/connection_repository.dart';
import 'package:terminal_ssh_app/core/storage/database.dart';
import 'package:terminal_ssh_app/core/storage/secure_storage.dart';
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
// Mocks for ConnectionListNotifier tests
// ---------------------------------------------------------------------------

class _MockConnectionRepository extends Mock implements ConnectionRepository {}

class _MockSecureStorageService extends Mock implements SecureStorageService {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    registerFallbackValue(const ConnectionsCompanion());
  });

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
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

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
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  // =====================================================================
  // connection_provider.dart
  // =====================================================================
  group('ConnectionListNotifier', () {
    late _MockConnectionRepository mockRepo;
    late _MockSecureStorageService mockStorage;
    late ProviderContainer container;

    setUp(() {
      mockRepo = _MockConnectionRepository();
      mockStorage = _MockSecureStorageService();

      container = ProviderContainer(overrides: [
        connectionRepositoryProvider.overrideWith((_) => mockRepo),
        secureStorageProvider.overrideWith((_) => mockStorage),
      ]);

      when(() => mockRepo.getAll()).thenAnswer((_) async => []);
      when(() => mockRepo.add(any())).thenAnswer((_) async => 1);
      when(() => mockRepo.update(any(), any())).thenAnswer((_) async => true);
      when(() => mockStorage.savePassword(any(), any())).thenAnswer((_) async {});
      when(() => mockStorage.deletePassword(any())).thenAnswer((_) async {});
      when(() => mockStorage.savePrivateKey(any(), any()))
          .thenAnswer((_) async {});
      when(() => mockStorage.deletePrivateKey(any())).thenAnswer((_) async {});
    });

    tearDown(() => container.dispose());

    Future<ConnectionListNotifier> getNotifier() async {
      await container.read(connectionListProvider.future);
      return container.read(connectionListProvider.notifier);
    }

    group('_saveCredentials password (via addConnection)', () {
      test('non-empty password calls savePassword', () async {
        final notifier = await getNotifier();

        await notifier.addConnection(
          label: 'test',
          host: 'host',
          port: 22,
          username: 'user',
          authMethod: 'password',
          password: 'secret',
        );

        verify(() => mockStorage.savePassword(1, 'secret')).called(1);
        verifyNever(() => mockStorage.deletePassword(any()));
      });

      test('empty password calls deletePassword', () async {
        final notifier = await getNotifier();

        await notifier.addConnection(
          label: 'test',
          host: 'host',
          port: 22,
          username: 'user',
          authMethod: 'password',
          password: '',
        );

        verify(() => mockStorage.deletePassword(1)).called(1);
        verifyNever(() => mockStorage.savePassword(any(), any()));
      });

      test('null password touches neither savePassword nor deletePassword',
          () async {
        final notifier = await getNotifier();

        await notifier.addConnection(
          label: 'test',
          host: 'host',
          port: 22,
          username: 'user',
          authMethod: 'key',
          password: null,
        );

        verifyNever(() => mockStorage.savePassword(any(), any()));
        verifyNever(() => mockStorage.deletePassword(any()));
      });
    });

    group('_saveCredentials privateKeyPem (via updateConnection)', () {
      test('non-empty privateKeyPem calls savePrivateKey', () async {
        final notifier = await getNotifier();

        await notifier.updateConnection(
          id: 42,
          label: 'test',
          host: 'host',
          port: 22,
          username: 'user',
          authMethod: 'key',
          privateKeyPem: '-----BEGIN RSA PRIVATE KEY-----\nMIIE...',
        );

        verify(() => mockStorage.savePrivateKey(
              42,
              '-----BEGIN RSA PRIVATE KEY-----\nMIIE...',
            )).called(1);
        verifyNever(() => mockStorage.deletePrivateKey(any()));
      });

      test('empty privateKeyPem calls deletePrivateKey', () async {
        final notifier = await getNotifier();

        await notifier.updateConnection(
          id: 42,
          label: 'test',
          host: 'host',
          port: 22,
          username: 'user',
          authMethod: 'key',
          privateKeyPem: '',
        );

        verify(() => mockStorage.deletePrivateKey(42)).called(1);
        verifyNever(() => mockStorage.savePrivateKey(any(), any()));
      });

      test(
          'null privateKeyPem touches neither savePrivateKey nor deletePrivateKey',
          () async {
        final notifier = await getNotifier();

        await notifier.updateConnection(
          id: 42,
          label: 'test',
          host: 'host',
          port: 22,
          username: 'user',
          authMethod: 'password',
          privateKeyPem: null,
        );

        verifyNever(() => mockStorage.savePrivateKey(any(), any()));
        verifyNever(() => mockStorage.deletePrivateKey(any()));
      });
    });

    group('deleteConnection', () {
      setUp(() {
        when(() => mockRepo.delete(any())).thenAnswer((_) async => 1);
      });

      test('calls repository delete', () async {
        final notifier = await getNotifier();
        await notifier.deleteConnection(5);
        verify(() => mockRepo.delete(5)).called(1);
      });

      test('invalidateSelf is called even when delete throws', () async {
        when(() => mockRepo.delete(any())).thenThrow(Exception('db error'));

        final notifier = await getNotifier();

        await expectLater(
          notifier.deleteConnection(5),
          throwsA(isA<Exception>()),
        );

        final result = await container.read(connectionListProvider.future);
        expect(result, isEmpty);
      });
    });

    group('_saveCredentials always calls invalidateSelf', () {
      test('invalidateSelf is called even when storage write throws', () async {
        when(() => mockStorage.savePassword(any(), any()))
            .thenThrow(Exception('storage error'));

        final notifier = await getNotifier();

        await expectLater(
          notifier.addConnection(
            label: 'test',
            host: 'host',
            port: 22,
            username: 'user',
            authMethod: 'password',
            password: 'secret',
          ),
          throwsA(isA<Exception>()),
        );
      });
    });
  });
}
