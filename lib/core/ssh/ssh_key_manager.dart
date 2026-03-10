import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SshKeyManager {
  SshKeyManager({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _keyPrefix = 'ssh_key_';

  Future<void> savePrivateKey(String keyId, String pemContent) async {
    await _storage.write(key: '$_keyPrefix$keyId', value: pemContent);
  }

  Future<String?> loadPrivateKey(String keyId) async {
    return _storage.read(key: '$_keyPrefix$keyId');
  }

  Future<void> deletePrivateKey(String keyId) async {
    await _storage.delete(key: '$_keyPrefix$keyId');
  }

  Future<List<String>> listKeyIds() async {
    final all = await _storage.readAll();
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
