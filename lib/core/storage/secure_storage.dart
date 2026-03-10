import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  SecureStorageService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _passwordPrefix = 'conn_pwd_';
  static const _keyPrefix = 'conn_key_';
  static const _passphrasePrefix = 'conn_pp_';

  Future<void> savePassword(int connectionId, String password) async {
    await _storage.write(
      key: '$_passwordPrefix$connectionId',
      value: password,
    );
  }

  Future<String?> loadPassword(int connectionId) async {
    return _storage.read(key: '$_passwordPrefix$connectionId');
  }

  Future<void> deletePassword(int connectionId) async {
    await _storage.delete(key: '$_passwordPrefix$connectionId');
  }

  Future<void> savePrivateKey(int connectionId, String pem) async {
    await _storage.write(key: '$_keyPrefix$connectionId', value: pem);
  }

  Future<String?> loadPrivateKey(int connectionId) async {
    return _storage.read(key: '$_keyPrefix$connectionId');
  }

  Future<void> deletePrivateKey(int connectionId) async {
    await _storage.delete(key: '$_keyPrefix$connectionId');
  }

  Future<void> savePassphrase(int connectionId, String passphrase) async {
    await _storage.write(
      key: '$_passphrasePrefix$connectionId',
      value: passphrase,
    );
  }

  Future<String?> loadPassphrase(int connectionId) async {
    return _storage.read(key: '$_passphrasePrefix$connectionId');
  }

  Future<void> deletePassphrase(int connectionId) async {
    await _storage.delete(key: '$_passphrasePrefix$connectionId');
  }

  Future<void> deleteAllForConnection(int connectionId) async {
    await deletePassword(connectionId);
    await deletePrivateKey(connectionId);
    await deletePassphrase(connectionId);
  }
}
