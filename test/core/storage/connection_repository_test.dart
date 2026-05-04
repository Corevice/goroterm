import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:terminal_ssh_app/core/storage/connection_repository.dart';
import 'package:terminal_ssh_app/core/storage/database.dart';
import 'package:terminal_ssh_app/core/storage/secure_storage.dart';

class MockSecureStorageService extends Mock implements SecureStorageService {}

class MockFlutterSecureStorageRepo extends Mock implements FlutterSecureStorage {}

AppDatabase _openInMemory() => AppDatabase(NativeDatabase.memory());

ConnectionsCompanion _entry({
  String label = 'Test',
  String host = 'localhost',
  int port = 22,
  String username = 'user',
  String authMethod = 'password',
}) =>
    ConnectionsCompanion(
      label: Value(label),
      host: Value(host),
      port: Value(port),
      username: Value(username),
      authMethod: Value(authMethod),
    );

void main() {
  late AppDatabase db;
  late MockSecureStorageService mockSecure;
  late ConnectionRepository repo;

  setUp(() {
    db = _openInMemory();
    mockSecure = MockSecureStorageService();
    repo = ConnectionRepository(db: db, secureStorage: mockSecure);
  });

  tearDown(() => db.close());

  group('getAll', () {
    test('returns empty list when no connections', () async {
      final result = await repo.getAll();
      expect(result, isEmpty);
    });

    test('returns connections ordered by createdAt descending', () async {
      final t0 = DateTime.now();
      final t1 = t0.add(const Duration(seconds: 1));

      await db.into(db.connections).insert(ConnectionsCompanion(
            label: const Value('First'),
            host: const Value('localhost'),
            username: const Value('user'),
            createdAt: Value(t0),
          ));
      await db.into(db.connections).insert(ConnectionsCompanion(
            label: const Value('Second'),
            host: const Value('localhost'),
            username: const Value('user'),
            createdAt: Value(t1),
          ));

      final result = await repo.getAll();
      expect(result.length, 2);
      expect(result.first.label, 'Second');
      expect(result.last.label, 'First');
    });
  });

  group('getById', () {
    test('returns null for unknown id', () async {
      final result = await repo.getById(999);
      expect(result, isNull);
    });

    test('returns the correct connection', () async {
      final id = await repo.add(_entry(label: 'MyServer', host: '10.0.0.1'));
      final result = await repo.getById(id);
      expect(result, isNotNull);
      expect(result!.label, 'MyServer');
      expect(result.host, '10.0.0.1');
    });
  });

  group('add', () {
    test('inserts a connection and returns a positive id', () async {
      final id = await repo.add(_entry(label: 'New'));
      expect(id, greaterThan(0));
    });

    test('inserted connection is retrievable', () async {
      final id = await repo.add(_entry(
        label: 'Prod',
        host: '192.168.1.1',
        port: 2222,
        username: 'admin',
        authMethod: 'key',
      ));
      final conn = await repo.getById(id);
      expect(conn!.label, 'Prod');
      expect(conn.port, 2222);
      expect(conn.authMethod, 'key');
    });
  });

  group('update', () {
    test('returns true when row is updated', () async {
      final id = await repo.add(_entry(label: 'Old'));
      final ok =
          await repo.update(id, _entry(label: 'New', host: 'updated.host'));
      expect(ok, isTrue);

      final conn = await repo.getById(id);
      expect(conn!.label, 'New');
      expect(conn.host, 'updated.host');
    });

    test('returns false for non-existent id', () async {
      final ok = await repo.update(999, _entry(label: 'Ghost'));
      expect(ok, isFalse);
    });
  });

  group('delete', () {
    test('removes the connection and calls deleteAllForConnection', () async {
      when(() => mockSecure.deleteAllForConnection(any()))
          .thenAnswer((_) async {});

      final id = await repo.add(_entry(label: 'ToDelete'));
      final rowsDeleted = await repo.delete(id);

      expect(rowsDeleted, 1);
      expect(await repo.getById(id), isNull);
      verify(() => mockSecure.deleteAllForConnection(id)).called(1);
    });

    test('calls deleteAllForConnection before DB delete', () async {
      final callOrder = <String>[];

      when(() => mockSecure.deleteAllForConnection(any())).thenAnswer((_) async {
        callOrder.add('secure');
      });

      final id = await repo.add(_entry(label: 'Ordered'));
      await repo.delete(id);

      // secure storage cleanup is the first recorded action
      expect(callOrder.first, 'secure');
    });

    test('returns 0 for non-existent id (secure still called)', () async {
      when(() => mockSecure.deleteAllForConnection(any()))
          .thenAnswer((_) async {});

      final rowsDeleted = await repo.delete(999);
      expect(rowsDeleted, 0);
      verify(() => mockSecure.deleteAllForConnection(999)).called(1);
    });
  });

  group('watchAll', () {
    test('emits empty list initially', () async {
      expect(repo.watchAll(), emits(isEmpty));
    });

    test('emits updated list when connection is added', () async {
      final collected = <List<Connection>>[];
      final sub = repo.watchAll().listen(collected.add);

      // wait for initial empty emission
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(collected, isNotEmpty);
      expect(collected.last, isEmpty);

      await repo.add(_entry(label: 'Watched'));

      // wait for the update emission
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(collected.last.length, 1);
      expect(collected.last.first.label, 'Watched');

      await sub.cancel();
    });
  });

  // =====================================================================
  // secure_storage.dart
  // =====================================================================
  group('SecureStorageService', () {
    late MockFlutterSecureStorageRepo mockSecureStorage;
    late SecureStorageService secureService;

    setUp(() {
      mockSecureStorage = MockFlutterSecureStorageRepo();
      secureService = SecureStorageService(storage: mockSecureStorage);
    });

    group('savePassword / loadPassword', () {
      test('saves and loads password for a connection', () async {
        when(() => mockSecureStorage.write(key: 'conn_pwd_1', value: 'secret'))
            .thenAnswer((_) async {});
        when(() => mockSecureStorage.read(key: 'conn_pwd_1'))
            .thenAnswer((_) async => 'secret');

        await secureService.savePassword(1, 'secret');
        final result = await secureService.loadPassword(1);

        expect(result, equals('secret'));
        verify(() => mockSecureStorage.write(key: 'conn_pwd_1', value: 'secret'))
            .called(1);
      });

      test('loadPassword returns null when not set', () async {
        when(() => mockSecureStorage.read(key: 'conn_pwd_99'))
            .thenAnswer((_) async => null);

        expect(await secureService.loadPassword(99), isNull);
      });
    });

    group('deletePassword', () {
      test('deletes password so loadPassword returns null', () async {
        when(() => mockSecureStorage.delete(key: 'conn_pwd_2'))
            .thenAnswer((_) async {});
        when(() => mockSecureStorage.read(key: 'conn_pwd_2'))
            .thenAnswer((_) async => null);

        await secureService.deletePassword(2);
        expect(await secureService.loadPassword(2), isNull);
        verify(() => mockSecureStorage.delete(key: 'conn_pwd_2')).called(1);
      });
    });

    group('savePrivateKey / loadPrivateKey', () {
      test('saves and loads private key for a connection', () async {
        when(() => mockSecureStorage.write(
              key: 'conn_key_3',
              value: '-----BEGIN OPENSSH PRIVATE KEY-----',
            )).thenAnswer((_) async {});
        when(() => mockSecureStorage.read(key: 'conn_key_3'))
            .thenAnswer((_) async => '-----BEGIN OPENSSH PRIVATE KEY-----');

        await secureService.savePrivateKey(3, '-----BEGIN OPENSSH PRIVATE KEY-----');
        expect(await secureService.loadPrivateKey(3), equals('-----BEGIN OPENSSH PRIVATE KEY-----'));
        verify(() => mockSecureStorage.write(
              key: 'conn_key_3',
              value: '-----BEGIN OPENSSH PRIVATE KEY-----',
            )).called(1);
      });

      test('loadPrivateKey returns null when not set', () async {
        when(() => mockSecureStorage.read(key: 'conn_key_7'))
            .thenAnswer((_) async => null);
        expect(await secureService.loadPrivateKey(7), isNull);
      });
    });

    group('savePassphrase / loadPassphrase', () {
      test('saves and loads passphrase for a connection', () async {
        when(() => mockSecureStorage.write(key: 'conn_pp_1', value: 'mypass'))
            .thenAnswer((_) async {});
        when(() => mockSecureStorage.read(key: 'conn_pp_1'))
            .thenAnswer((_) async => 'mypass');

        await secureService.savePassphrase(1, 'mypass');
        expect(await secureService.loadPassphrase(1), equals('mypass'));
        verify(() => mockSecureStorage.write(key: 'conn_pp_1', value: 'mypass'))
            .called(1);
      });

      test('loadPassphrase returns null when not set', () async {
        when(() => mockSecureStorage.read(key: 'conn_pp_42'))
            .thenAnswer((_) async => null);
        expect(await secureService.loadPassphrase(42), isNull);
      });
    });

    group('deleteAllForConnection', () {
      test('deletes password, private key, and passphrase together', () async {
        when(() => mockSecureStorage.delete(key: 'conn_pwd_5'))
            .thenAnswer((_) async {});
        when(() => mockSecureStorage.delete(key: 'conn_key_5'))
            .thenAnswer((_) async {});
        when(() => mockSecureStorage.delete(key: 'conn_pp_5'))
            .thenAnswer((_) async {});

        await secureService.deleteAllForConnection(5);

        verify(() => mockSecureStorage.delete(key: 'conn_pwd_5')).called(1);
        verify(() => mockSecureStorage.delete(key: 'conn_key_5')).called(1);
        verify(() => mockSecureStorage.delete(key: 'conn_pp_5')).called(1);
      });
    });
  });
}
