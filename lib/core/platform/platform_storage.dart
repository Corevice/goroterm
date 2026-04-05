import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'macos_kv_store.dart';

/// Thin wrapper that routes key-value reads and writes to the
/// platform-appropriate secure storage backend.
///
/// - macOS: [MacosKvStore] (NSUserDefaults-backed sandbox storage)
/// - Other platforms: [FlutterSecureStorage]
class PlatformStorage {
  PlatformStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<void> write(String key, String value) async {
    if (Platform.isMacOS) {
      await MacosKvStore.write(key, value);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  Future<String?> read(String key) async {
    if (Platform.isMacOS) {
      return MacosKvStore.read(key);
    } else {
      return _storage.read(key: key);
    }
  }

  Future<void> delete(String key) async {
    if (Platform.isMacOS) {
      await MacosKvStore.delete(key);
    } else {
      await _storage.delete(key: key);
    }
  }

  Future<Map<String, String>> readAll() async {
    if (Platform.isMacOS) {
      return MacosKvStore.readAll();
    } else {
      return _storage.readAll();
    }
  }
}
