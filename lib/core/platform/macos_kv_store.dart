import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// macOS file-based key-value store.
///
/// flutter_secure_storage on macOS requires the Keychain entitlement which can
/// cause issues in certain build configurations. This helper stores values as
/// base64-encoded UTF-8 files under the app's support directory as a fallback.
///
/// Used by [KnownHostsStore] and [SshKeyManager] on macOS.
class MacosKvStore {
  MacosKvStore._();

  static Directory? _cacheDir;

  static Future<Directory> _getDir({bool create = true}) async {
    if (_cacheDir == null) {
      final support = await getApplicationSupportDirectory();
      _cacheDir = Directory(p.join(support.path, 'secure_kv'));
    }
    if (create) await _cacheDir!.create(recursive: true);
    return _cacheDir!;
  }

  static Future<File> _fileFor(String key) async {
    final dir = await _getDir();
    final encoded = Uri.encodeComponent(key);
    return File(p.join(dir.path, encoded));
  }

  /// Overrides the cache directory for unit testing.
  ///
  /// Inject a [Directory] pointing at a temporary path so tests avoid the
  /// platform `getApplicationSupportDirectory()` call.
  @visibleForTesting
  static void setCacheDirForTesting(Directory dir) => _cacheDir = dir;

  static Future<void> write(String key, String value) async {
    final f = await _fileFor(key);
    await f.writeAsString(base64Encode(utf8.encode(value)), flush: true);
  }

  static Future<String?> read(String key) async {
    final f = await _fileFor(key);
    if (!await f.exists()) return null;
    try {
      return utf8.decode(base64Decode(await f.readAsString()));
    } catch (e) {
      debugPrint('[MacosKvStore] read error: $e');
      return null;
    }
  }

  static Future<void> delete(String key) async {
    final f = await _fileFor(key);
    if (await f.exists()) await f.delete();
  }

  /// Returns all stored key-value pairs.
  ///
  /// Returns an empty map (without creating the directory) if the store
  /// directory does not yet exist.
  static Future<Map<String, String>> readAll() async {
    final dir = await _getDir(create: false);
    if (!await dir.exists()) return {};
    final result = <String, String>{};
    await for (final entity in dir.list()) {
      if (entity is File) {
        final key = Uri.decodeComponent(p.basename(entity.path));
        try {
          final encoded = await entity.readAsString();
          result[key] = utf8.decode(base64Decode(encoded));
        } catch (_) {}
      }
    }
    return result;
  }
}
