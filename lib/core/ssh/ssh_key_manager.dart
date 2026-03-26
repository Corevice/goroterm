import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class SshKeyManager {
  SshKeyManager({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _keyPrefix = 'ssh_key_';

  // --- macOS file-based fallback ---

  static Directory? _cacheDir;

  Future<File> _fileFor(String key) async {
    if (_cacheDir == null) {
      final dir = await getApplicationSupportDirectory();
      _cacheDir = Directory(p.join(dir.path, 'secure_kv'));
      await _cacheDir!.create(recursive: true);
    }
    final safe = key.replaceAll(RegExp(r'[^\w\-.]'), '_');
    return File(p.join(_cacheDir!.path, safe));
  }

  Future<void> _write(String key, String value) async {
    if (Platform.isMacOS) {
      final f = await _fileFor(key);
      await f.writeAsString(base64Encode(utf8.encode(value)), flush: true);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  Future<String?> _read(String key) async {
    if (Platform.isMacOS) {
      final f = await _fileFor(key);
      if (!await f.exists()) return null;
      try {
        return utf8.decode(base64Decode(await f.readAsString()));
      } catch (e) {
        debugPrint('[SshKeyManager] read error: $e');
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

  Future<Map<String, String>> _readAll() async {
    if (Platform.isMacOS) {
      if (_cacheDir == null) {
        final dir = await getApplicationSupportDirectory();
        _cacheDir = Directory(p.join(dir.path, 'secure_kv'));
        if (!await _cacheDir!.exists()) return {};
      }
      final result = <String, String>{};
      await for (final entity in _cacheDir!.list()) {
        if (entity is File) {
          final key = p.basename(entity.path);
          try {
            final encoded = await entity.readAsString();
            result[key] = utf8.decode(base64Decode(encoded));
          } catch (_) {}
        }
      }
      return result;
    } else {
      return _storage.readAll();
    }
  }

  // --- public API ---

  Future<void> savePrivateKey(String keyId, String pemContent) =>
      _write('$_keyPrefix$keyId', pemContent);

  Future<String?> loadPrivateKey(String keyId) =>
      _read('$_keyPrefix$keyId');

  Future<void> deletePrivateKey(String keyId) =>
      _delete('$_keyPrefix$keyId');

  Future<List<String>> listKeyIds() async {
    final all = await _readAll();
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
