import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// macOS ではファイルベース、それ以外では Keychain を使うストレージ。
class SecureStorageService {
  SecureStorageService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _passwordPrefix = 'conn_pwd_';
  static const _keyPrefix = 'conn_key_';
  static const _passphrasePrefix = 'conn_pp_';

  // --- file-based fallback for macOS ---

  static Directory? _cacheDir;

  Future<File> _fileFor(String key) async {
    if (_cacheDir == null) {
      final dir = await getApplicationSupportDirectory();
      _cacheDir = Directory(p.join(dir.path, 'secure_kv'));
      await _cacheDir!.create(recursive: true);
    }
    // sanitise key for filename
    final safe = key.replaceAll(RegExp(r'[^\w\-.]'), '_');
    return File(p.join(_cacheDir!.path, safe));
  }

  Future<void> _write(String key, String value) async {
    if (Platform.isMacOS) {
      final f = await _fileFor(key);
      final encoded = base64Encode(utf8.encode(value));
      await f.writeAsString(encoded, flush: true);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  Future<String?> _read(String key) async {
    if (Platform.isMacOS) {
      final f = await _fileFor(key);
      if (!await f.exists()) return null;
      try {
        final encoded = await f.readAsString();
        return utf8.decode(base64Decode(encoded));
      } catch (e) {
        debugPrint('[SecureStorage] read error: $e');
        return null;
      }
    } else {
      return _storage.read(key: key);
    }
  }

  Future<void> _delete(String key) async {
    if (Platform.isMacOS) {
      final f = await _fileFor(key);
      if (await f.exists()) await f.delete();
    } else {
      await _storage.delete(key: key);
    }
  }

  // --- public API (unchanged signatures) ---

  Future<void> savePassword(int connectionId, String password) =>
      _write('$_passwordPrefix$connectionId', password);

  Future<String?> loadPassword(int connectionId) =>
      _read('$_passwordPrefix$connectionId');

  Future<void> deletePassword(int connectionId) =>
      _delete('$_passwordPrefix$connectionId');

  Future<void> savePrivateKey(int connectionId, String pem) =>
      _write('$_keyPrefix$connectionId', pem);

  Future<String?> loadPrivateKey(int connectionId) =>
      _read('$_keyPrefix$connectionId');

  Future<void> deletePrivateKey(int connectionId) =>
      _delete('$_keyPrefix$connectionId');

  Future<void> savePassphrase(int connectionId, String passphrase) =>
      _write('$_passphrasePrefix$connectionId', passphrase);

  Future<String?> loadPassphrase(int connectionId) =>
      _read('$_passphrasePrefix$connectionId');

  Future<void> deletePassphrase(int connectionId) =>
      _delete('$_passphrasePrefix$connectionId');

  Future<void> deleteAllForConnection(int connectionId) async {
    await deletePassword(connectionId);
    await deletePrivateKey(connectionId);
    await deletePassphrase(connectionId);
  }
}
