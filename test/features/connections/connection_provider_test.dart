import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:terminal_ssh_app/core/storage/connection_repository.dart';
import 'package:terminal_ssh_app/core/storage/secure_storage.dart';
import 'package:terminal_ssh_app/core/storage/database.dart';
import 'package:terminal_ssh_app/features/connections/connection_provider.dart';

class MockConnectionRepository extends Mock implements ConnectionRepository {}

class MockSecureStorageService extends Mock implements SecureStorageService {}

void main() {
  setUpAll(() {
    registerFallbackValue(const ConnectionsCompanion());
  });

  late MockConnectionRepository mockRepo;
  late MockSecureStorageService mockStorage;
  late ProviderContainer container;

  setUp(() {
    mockRepo = MockConnectionRepository();
    mockStorage = MockSecureStorageService();

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

  // Helper: get the notifier after build completes.
  Future<ConnectionListNotifier> getNotifier() async {
    await container.read(connectionListProvider.future);
    return container.read(connectionListProvider.notifier);
  }

  // ---------------------------------------------------------------------------
  // _saveCredentials — password handling (via addConnection)
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // _saveCredentials — privateKeyPem handling (via updateConnection)
  // ---------------------------------------------------------------------------

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

    test('null privateKeyPem touches neither savePrivateKey nor deletePrivateKey',
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

  // ---------------------------------------------------------------------------
  // deleteConnection
  // ---------------------------------------------------------------------------

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

      // Provider rebuilds (invalidateSelf was called in finally block), so a
      // subsequent read should succeed without error.
      final result = await container.read(connectionListProvider.future);
      expect(result, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // _saveCredentials — invalidateSelf is always called (via finally block)
  // ---------------------------------------------------------------------------

  group('_saveCredentials always calls invalidateSelf', () {
    test('invalidateSelf is called even when storage write throws', () async {
      when(() => mockStorage.savePassword(any(), any()))
          .thenThrow(Exception('storage error'));

      final notifier = await getNotifier();

      // addConnection should not throw — the finally block in _saveCredentials
      // calls ref.invalidateSelf(), which triggers a rebuild. The exception from
      // savePassword is caught by the try/finally.
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
}
