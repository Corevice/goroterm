import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:terminal_ssh_app/core/ssh/known_hosts_store.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late MockFlutterSecureStorage mockStorage;
  late KnownHostsStore store;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    store = KnownHostsStore(storage: mockStorage);
  });

  group('computeFingerprint', () {
    test('should return consistent SHA-256 fingerprint for same input', () {
      final hostKey = Uint8List.fromList([1, 2, 3, 4, 5]);
      final fp1 = store.computeFingerprint(hostKey);
      final fp2 = store.computeFingerprint(hostKey);
      expect(fp1, equals(fp2));
      expect(fp1.isNotEmpty, isTrue);
    });

    test('should return different fingerprints for different keys', () {
      final key1 = Uint8List.fromList([1, 2, 3]);
      final key2 = Uint8List.fromList([4, 5, 6]);
      expect(
        store.computeFingerprint(key1),
        isNot(equals(store.computeFingerprint(key2))),
      );
    });
  });

  group('verify', () {
    test('should return null for unknown host', () async {
      when(() => mockStorage.read(key: 'known_host_example.com_22'))
          .thenAnswer((_) async => null);

      final result = await store.verify(
        'example.com',
        22,
        Uint8List.fromList([1, 2, 3]),
      );
      expect(result, isNull);
    });

    test('should return true for matching fingerprint', () async {
      final hostKey = Uint8List.fromList([1, 2, 3]);
      final fingerprint = store.computeFingerprint(hostKey);

      when(() => mockStorage.read(key: 'known_host_example.com_22'))
          .thenAnswer((_) async => fingerprint);

      final result = await store.verify('example.com', 22, hostKey);
      expect(result, isTrue);
    });

    test('should return false for mismatched fingerprint', () async {
      final hostKey = Uint8List.fromList([1, 2, 3]);

      when(() => mockStorage.read(key: 'known_host_example.com_22'))
          .thenAnswer((_) async => 'different_fingerprint');

      final result = await store.verify('example.com', 22, hostKey);
      expect(result, isFalse);
    });
  });

  group('saveFingerprint', () {
    test('should save fingerprint to secure storage', () async {
      when(() => mockStorage.write(
            key: 'known_host_example.com_22',
            value: 'test_fingerprint',
          )).thenAnswer((_) async {});

      await store.saveFingerprint('example.com', 22, 'test_fingerprint');

      verify(() => mockStorage.write(
            key: 'known_host_example.com_22',
            value: 'test_fingerprint',
          )).called(1);
    });
  });

  group('removeFingerprint', () {
    test('should delete fingerprint from secure storage', () async {
      when(() => mockStorage.delete(key: 'known_host_example.com_22'))
          .thenAnswer((_) async {});

      await store.removeFingerprint('example.com', 22);

      verify(() => mockStorage.delete(key: 'known_host_example.com_22'))
          .called(1);
    });
  });
}
