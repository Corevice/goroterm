import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class KnownHostsStore {
  KnownHostsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _prefix = 'known_host_';

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
        debugPrint('[KnownHostsStore] read error: $e');
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

  // --- public API ---

  String computeFingerprint(Uint8List hostKey) {
    final digest = sha256.convert(hostKey);
    return base64Encode(digest.bytes);
  }

  String _storageKey(String host, int port) => '$_prefix${host}_$port';

  Future<String?> getStoredFingerprint(String host, int port) =>
      _read(_storageKey(host, port));

  Future<void> saveFingerprint(String host, int port, String fingerprint) =>
      _write(_storageKey(host, port), fingerprint);

  Future<void> removeFingerprint(String host, int port) =>
      _delete(_storageKey(host, port));

  Future<bool?> verify(String host, int port, Uint8List hostKey) async {
    final fingerprint = computeFingerprint(hostKey);
    final stored = await getStoredFingerprint(host, port);
    if (stored == null) return null;
    return stored == fingerprint;
  }
}
