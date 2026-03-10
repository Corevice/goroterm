import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class KnownHostsStore {
  KnownHostsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _prefix = 'known_host_';

  String computeFingerprint(Uint8List hostKey) {
    final digest = sha256.convert(hostKey);
    return base64Encode(digest.bytes);
  }

  String _storageKey(String host, int port) => '$_prefix${host}_$port';

  Future<String?> getStoredFingerprint(String host, int port) async {
    return _storage.read(key: _storageKey(host, port));
  }

  Future<void> saveFingerprint(String host, int port, String fingerprint) async {
    await _storage.write(key: _storageKey(host, port), value: fingerprint);
  }

  Future<void> removeFingerprint(String host, int port) async {
    await _storage.delete(key: _storageKey(host, port));
  }

  /// Returns true if the host key matches stored fingerprint.
  /// Returns false if there's a mismatch (potential MITM).
  /// Returns null if no stored fingerprint (first connection).
  Future<bool?> verify(String host, int port, Uint8List hostKey) async {
    final fingerprint = computeFingerprint(hostKey);
    final stored = await getStoredFingerprint(host, port);
    if (stored == null) return null;
    return stored == fingerprint;
  }
}
