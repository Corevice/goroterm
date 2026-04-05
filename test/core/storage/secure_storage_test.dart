import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:terminal_ssh_app/core/storage/secure_storage.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late MockFlutterSecureStorage mockStorage;
  late SecureStorageService service;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    service = SecureStorageService(storage: mockStorage);
  });

  group('savePassword / loadPassword', () {
    test('saves and loads password for a connection', () async {
      when(() => mockStorage.write(key: 'conn_pwd_1', value: 'secret'))
          .thenAnswer((_) async {});
      when(() => mockStorage.read(key: 'conn_pwd_1'))
          .thenAnswer((_) async => 'secret');

      await service.savePassword(1, 'secret');
      final result = await service.loadPassword(1);

      expect(result, equals('secret'));
      verify(() => mockStorage.write(key: 'conn_pwd_1', value: 'secret'))
          .called(1);
    });

    test('loadPassword returns null when not set', () async {
      when(() => mockStorage.read(key: 'conn_pwd_99'))
          .thenAnswer((_) async => null);

      final result = await service.loadPassword(99);

      expect(result, isNull);
    });
  });

  group('deletePassword', () {
    test('deletes password so loadPassword returns null', () async {
      when(() => mockStorage.delete(key: 'conn_pwd_2'))
          .thenAnswer((_) async {});
      when(() => mockStorage.read(key: 'conn_pwd_2'))
          .thenAnswer((_) async => null);

      await service.deletePassword(2);
      final result = await service.loadPassword(2);

      verify(() => mockStorage.delete(key: 'conn_pwd_2')).called(1);
      expect(result, isNull);
    });
  });

  group('savePrivateKey / loadPrivateKey', () {
    test('saves and loads private key for a connection', () async {
      when(() => mockStorage.write(
            key: 'conn_key_3',
            value: '-----BEGIN OPENSSH PRIVATE KEY-----',
          )).thenAnswer((_) async {});
      when(() => mockStorage.read(key: 'conn_key_3'))
          .thenAnswer((_) async => '-----BEGIN OPENSSH PRIVATE KEY-----');

      await service.savePrivateKey(3, '-----BEGIN OPENSSH PRIVATE KEY-----');
      final result = await service.loadPrivateKey(3);

      expect(result, equals('-----BEGIN OPENSSH PRIVATE KEY-----'));
      verify(() => mockStorage.write(
            key: 'conn_key_3',
            value: '-----BEGIN OPENSSH PRIVATE KEY-----',
          )).called(1);
    });

    test('loadPrivateKey returns null when not set', () async {
      when(() => mockStorage.read(key: 'conn_key_7'))
          .thenAnswer((_) async => null);

      final result = await service.loadPrivateKey(7);

      expect(result, isNull);
    });
  });

  group('deletePrivateKey', () {
    test('deletes private key so loadPrivateKey returns null', () async {
      when(() => mockStorage.delete(key: 'conn_key_4'))
          .thenAnswer((_) async {});
      when(() => mockStorage.read(key: 'conn_key_4'))
          .thenAnswer((_) async => null);

      await service.deletePrivateKey(4);
      final result = await service.loadPrivateKey(4);

      verify(() => mockStorage.delete(key: 'conn_key_4')).called(1);
      expect(result, isNull);
    });
  });

  group('savePassphrase / loadPassphrase', () {
    test('saves and loads passphrase for a connection', () async {
      when(() => mockStorage.write(key: 'conn_pp_1', value: 'mypass'))
          .thenAnswer((_) async {});
      when(() => mockStorage.read(key: 'conn_pp_1'))
          .thenAnswer((_) async => 'mypass');

      await service.savePassphrase(1, 'mypass');
      final result = await service.loadPassphrase(1);

      expect(result, equals('mypass'));
      verify(() => mockStorage.write(key: 'conn_pp_1', value: 'mypass'))
          .called(1);
    });

    test('loadPassphrase returns null when not set', () async {
      when(() => mockStorage.read(key: 'conn_pp_42'))
          .thenAnswer((_) async => null);

      final result = await service.loadPassphrase(42);

      expect(result, isNull);
    });
  });

  group('deletePassphrase', () {
    test('deletes passphrase so loadPassphrase returns null', () async {
      when(() => mockStorage.delete(key: 'conn_pp_1'))
          .thenAnswer((_) async {});
      when(() => mockStorage.read(key: 'conn_pp_1'))
          .thenAnswer((_) async => null);

      await service.deletePassphrase(1);
      final result = await service.loadPassphrase(1);

      verify(() => mockStorage.delete(key: 'conn_pp_1')).called(1);
      expect(result, isNull);
    });
  });

  group('deleteAllForConnection', () {
    test('deletes password, private key, and passphrase together', () async {
      when(() => mockStorage.delete(key: 'conn_pwd_5'))
          .thenAnswer((_) async {});
      when(() => mockStorage.delete(key: 'conn_key_5'))
          .thenAnswer((_) async {});
      when(() => mockStorage.delete(key: 'conn_pp_5'))
          .thenAnswer((_) async {});

      await service.deleteAllForConnection(5);

      verify(() => mockStorage.delete(key: 'conn_pwd_5')).called(1);
      verify(() => mockStorage.delete(key: 'conn_key_5')).called(1);
      verify(() => mockStorage.delete(key: 'conn_pp_5')).called(1);
    });
  });
}
