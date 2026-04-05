import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_key_manager.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

// Test fixtures sourced from dartssh2's own test suite.
// These are throwaway keys used only for unit testing — never used in production.
const _ed25519Unencrypted = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBZnnnYZjFQ7Zt0gMyJ2YYmDINTucLFWY81/Wuv2aOIpAAAAKBQ6gOSUOoD
kgAAAAtzc2gtZWQyNTUxOQAAACBZnnnYZjFQ7Zt0gMyJ2YYmDINTucLFWY81/Wuv2aOIpA
AAAEAP8fq0hjlR3jhL7pg+26PSaMiC1V/RrinVbo/4eBMRNFmeedhmMVDtm3SAzInZhiYM
g1O5wsVZjzX9a6/Zo4ikAAAAGWpmb3V0dHNAVVNBSkZPVVRUU00ubG9jYWwBAgME
-----END OPENSSH PRIVATE KEY-----
''';

const _ed25519Encrypted = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC0l9Iobg
dIkpFRXIVcSMo9AAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDl6gJA/mTwGajQU
GysVNxbg5DLxNkxNMr1N6nMqmILLAAAAoAheLDCmikMrd30h6Z3ug4h7WsK8TjBYToUkhO
1fu5qRd6pgCCeQt0C5eeJMkCSNTP+HZyWT9Vc67VCvzaECjFfXYJUsRYdknAXEO4oFc9fg
v8qGMQTFoIajXQk8Gk9QLqGQ0nupn4fZ3BhHhMoDIx7DWLhlvHddSJzgkORIt4bV8ntzh8
AK9jJFzpo0q4FnYkalW4fo/nosGUM/bq5LR2M=
-----END OPENSSH PRIVATE KEY-----
''';

const _ed25519Passphrase = '123456';

void main() {
  late MockFlutterSecureStorage mockStorage;
  late SshKeyManager manager;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    manager = SshKeyManager(storage: mockStorage);
  });

  // ---------------------------------------------------------------------------
  // savePrivateKey
  // ---------------------------------------------------------------------------

  group('savePrivateKey()', () {
    test('writes PEM content under ssh_key_-prefixed key', () async {
      when(() => mockStorage.write(
            key: 'ssh_key_my-key',
            value: '-----BEGIN RSA PRIVATE KEY-----',
          )).thenAnswer((_) async {});

      await manager.savePrivateKey('my-key', '-----BEGIN RSA PRIVATE KEY-----');

      verify(() => mockStorage.write(
            key: 'ssh_key_my-key',
            value: '-----BEGIN RSA PRIVATE KEY-----',
          )).called(1);
    });

    test('uses keyId verbatim as the suffix after ssh_key_', () async {
      when(() => mockStorage.write(
            key: 'ssh_key_prod-server-2024',
            value: 'pem',
          )).thenAnswer((_) async {});

      await manager.savePrivateKey('prod-server-2024', 'pem');

      verify(() => mockStorage.write(
            key: 'ssh_key_prod-server-2024',
            value: 'pem',
          )).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // loadPrivateKey
  // ---------------------------------------------------------------------------

  group('loadPrivateKey()', () {
    test('returns PEM content for an existing key', () async {
      when(() => mockStorage.read(key: 'ssh_key_my-key'))
          .thenAnswer((_) async => '-----BEGIN RSA PRIVATE KEY-----');

      final result = await manager.loadPrivateKey('my-key');

      expect(result, '-----BEGIN RSA PRIVATE KEY-----');
    });

    test('returns null for a non-existent key', () async {
      when(() => mockStorage.read(key: 'ssh_key_unknown'))
          .thenAnswer((_) async => null);

      final result = await manager.loadPrivateKey('unknown');

      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // deletePrivateKey
  // ---------------------------------------------------------------------------

  group('deletePrivateKey()', () {
    test('deletes the ssh_key_-prefixed storage entry', () async {
      when(() => mockStorage.delete(key: 'ssh_key_my-key'))
          .thenAnswer((_) async {});

      await manager.deletePrivateKey('my-key');

      verify(() => mockStorage.delete(key: 'ssh_key_my-key')).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // listKeyIds
  //
  // listKeyIds() reads all entries, filters by the 'ssh_key_' prefix,
  // then strips the prefix to return bare key IDs.
  // It must NOT return entries for other storage consumers (e.g. known_host_).
  // ---------------------------------------------------------------------------

  group('listKeyIds()', () {
    test('returns empty list when storage is empty', () async {
      when(() => mockStorage.readAll()).thenAnswer((_) async => {});

      final ids = await manager.listKeyIds();

      expect(ids, isEmpty);
    });

    test('returns stripped key IDs for ssh_key_-prefixed entries', () async {
      when(() => mockStorage.readAll()).thenAnswer((_) async => {
            'ssh_key_key1': 'pem1',
            'ssh_key_key2': 'pem2',
          });

      final ids = await manager.listKeyIds();

      expect(ids, unorderedEquals(['key1', 'key2']));
    });

    test('filters out non-ssh_key_ entries (e.g. known_host_)', () async {
      when(() => mockStorage.readAll()).thenAnswer((_) async => {
            'ssh_key_my-key': 'pem',
            'known_host_example.com_22': 'fingerprint',
            'some_other_entry': 'value',
          });

      final ids = await manager.listKeyIds();

      expect(ids, ['my-key']);
    });

    test('returns only ssh_key_ entries when mixed with known_host_ entries',
        () async {
      when(() => mockStorage.readAll()).thenAnswer((_) async => {
            'ssh_key_prod-server': 'pem1',
            'ssh_key_dev-server': 'pem2',
            'known_host_prod.example.com_22': 'fp1',
            'known_host_dev.example.com_22': 'fp2',
          });

      final ids = await manager.listKeyIds();

      expect(ids, unorderedEquals(['prod-server', 'dev-server']));
    });

    test('handles key IDs that contain hyphens and underscores', () async {
      when(() => mockStorage.readAll()).thenAnswer((_) async => {
            'ssh_key_my_server-01': 'pem',
          });

      final ids = await manager.listKeyIds();

      expect(ids, ['my_server-01']);
    });
  });

  // ---------------------------------------------------------------------------
  // isEncrypted
  // ---------------------------------------------------------------------------

  group('isEncrypted()', () {
    test('returns false for an unencrypted ed25519 key', () {
      expect(manager.isEncrypted(_ed25519Unencrypted), isFalse);
    });

    test('returns true for a passphrase-protected ed25519 key', () {
      expect(manager.isEncrypted(_ed25519Encrypted), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // parseKeyPair
  // ---------------------------------------------------------------------------

  group('parseKeyPair()', () {
    test('returns one OpenSSHEd25519KeyPair for an unencrypted ed25519 key',
        () {
      final pairs = manager.parseKeyPair(_ed25519Unencrypted);
      expect(pairs.length, 1);
      expect(pairs.single, isA<OpenSSHEd25519KeyPair>());
    });

    test('decrypts and returns key pair with correct passphrase', () {
      final pairs =
          manager.parseKeyPair(_ed25519Encrypted, _ed25519Passphrase);
      expect(pairs.length, 1);
      expect(pairs.single, isA<OpenSSHEd25519KeyPair>());
    });

    test('throws when passphrase is wrong for an encrypted key', () {
      expect(
        () => manager.parseKeyPair(_ed25519Encrypted, 'wrong-passphrase'),
        throwsA(anything),
      );
    });

    test('throws for completely invalid PEM content', () {
      expect(
        () => manager.parseKeyPair('not-a-pem-at-all'),
        throwsA(anything),
      );
    });
  });
}
