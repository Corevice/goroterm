import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/platform_storage.dart';

class SshKeyManager {
  SshKeyManager({FlutterSecureStorage? storage})
      : _store = PlatformStorage(storage);

  final PlatformStorage _store;
  static const _keyPrefix = 'ssh_key_';

  // --- public API ---

  Future<void> savePrivateKey(String keyId, String pemContent) =>
      _store.write('$_keyPrefix$keyId', pemContent);

  Future<String?> loadPrivateKey(String keyId) =>
      _store.read('$_keyPrefix$keyId');

  Future<void> deletePrivateKey(String keyId) =>
      _store.delete('$_keyPrefix$keyId');

  Future<List<String>> listKeyIds() async {
    final all = await _store.readAll();
    return all.keys
        .where((k) => k.startsWith(_keyPrefix))
        .map((k) => k.substring(_keyPrefix.length))
        .toList();
  }

  List<SSHKeyPair> parseKeyPair(String pem, [String? passphrase]) {
    return SSHKeyPair.fromPem(pem, passphrase);
  }

  bool isEncrypted(String pem) {
    return SSHKeyPair.isEncryptedPem(pem);
  }
}
