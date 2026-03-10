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
