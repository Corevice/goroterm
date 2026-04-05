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
    test('returns (null, null) for unknown host', () async {
      when(() => mockStorage.read(key: 'known_host_example.com:22'))
          .thenAnswer((_) async => null);

      final (matched, stored) = await store.verify(
        'example.com',
        22,
        Uint8List.fromList([1, 2, 3]),
      );
      expect(matched, isNull);
      expect(stored, isNull);
    });

    test('returns (true, storedFingerprint) for matching fingerprint', () async {
      final hostKey = Uint8List.fromList([1, 2, 3]);
      final fingerprint = store.computeFingerprint(hostKey);

      when(() => mockStorage.read(key: 'known_host_example.com:22'))
          .thenAnswer((_) async => fingerprint);

      final (matched, stored) = await store.verify('example.com', 22, hostKey);
      expect(matched, isTrue);
      expect(stored, equals(fingerprint));
    });

    test('returns (false, storedFingerprint) for mismatched fingerprint',
        () async {
      final hostKey = Uint8List.fromList([1, 2, 3]);
      const differentFp = 'different_fingerprint';

      when(() => mockStorage.read(key: 'known_host_example.com:22'))
          .thenAnswer((_) async => differentFp);

      final (matched, stored) = await store.verify('example.com', 22, hostKey);
      expect(matched, isFalse);
      expect(stored, equals(differentFp));
    });
  });

  group('saveFingerprint', () {
    test('should save fingerprint to secure storage', () async {
      when(() => mockStorage.write(
            key: 'known_host_example.com:22',
            value: 'test_fingerprint',
          )).thenAnswer((_) async {});

      await store.saveFingerprint('example.com', 22, 'test_fingerprint');

      verify(() => mockStorage.write(
            key: 'known_host_example.com:22',
            value: 'test_fingerprint',
          )).called(1);
    });
  });

  group('removeFingerprint', () {
    test('should delete fingerprint from secure storage', () async {
      when(() => mockStorage.delete(key: 'known_host_example.com:22'))
          .thenAnswer((_) async {});

      await store.removeFingerprint('example.com', 22);

      verify(() => mockStorage.delete(key: 'known_host_example.com:22'))
          .called(1);
    });
  });

  group('getStoredFingerprint', () {
    test('returns fingerprint when one is stored', () async {
      when(() => mockStorage.read(key: 'known_host_example.com:22'))
          .thenAnswer((_) async => 'stored_fp');

      final result = await store.getStoredFingerprint('example.com', 22);

      expect(result, 'stored_fp');
    });

    test('returns null when no fingerprint is stored', () async {
      when(() => mockStorage.read(key: 'known_host_example.com:22'))
          .thenAnswer((_) async => null);

      final result = await store.getStoredFingerprint('example.com', 22);

      expect(result, isNull);
    });
  });

  group('storage key uniqueness', () {
    test('hosts with underscores produce distinct keys from plain hosts', () {
      // "a_22" port 2 vs "a" port 222 — would collide with underscore separator
      // but are distinct with colon separator
      final store2 = KnownHostsStore(storage: mockStorage);
      // We verify via the public API: different (host, port) pairs must write
      // to different keys. We confirm by mocking distinct keys and ensuring
      // getStoredFingerprint for one does not read from the other.
      when(() => mockStorage.read(key: 'known_host_a_22:2'))
          .thenAnswer((_) async => 'fp_a');
      when(() => mockStorage.read(key: 'known_host_a:222'))
          .thenAnswer((_) async => 'fp_b');

      expect(
        store2.getStoredFingerprint('a_22', 2),
        completion('fp_a'),
      );
      expect(
        store2.getStoredFingerprint('a', 222),
        completion('fp_b'),
      );
    });
  });

  group('non-standard port numbers', () {
    test('saveFingerprint uses correct storage key for port 2222', () async {
      when(() => mockStorage.write(
            key: 'known_host_myserver.internal:2222',
            value: 'fp_2222',
          )).thenAnswer((_) async {});

      await store.saveFingerprint('myserver.internal', 2222, 'fp_2222');

      verify(() => mockStorage.write(
            key: 'known_host_myserver.internal:2222',
            value: 'fp_2222',
          )).called(1);
    });

    test('verify reads correct key for non-standard port', () async {
      final hostKey = Uint8List.fromList([10, 20, 30]);
      final fp = store.computeFingerprint(hostKey);

      when(() => mockStorage.read(key: 'known_host_192.168.1.1:2222'))
          .thenAnswer((_) async => fp);

      final (matched, stored) =
          await store.verify('192.168.1.1', 2222, hostKey);

      expect(matched, isTrue);
      expect(stored, fp);
    });

    test('removeFingerprint uses correct storage key for port 2222', () async {
      when(() => mockStorage.delete(key: 'known_host_example.com:2222'))
          .thenAnswer((_) async {});

      await store.removeFingerprint('example.com', 2222);

      verify(() => mockStorage.delete(key: 'known_host_example.com:2222'))
          .called(1);
    });
  });
}
