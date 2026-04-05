import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/platform_storage.dart';

class KnownHostsStore {
  KnownHostsStore({FlutterSecureStorage? storage})
      : _store = PlatformStorage(storage);

  final PlatformStorage _store;
  static const _prefix = 'known_host_';

  // --- public API ---

  String computeFingerprint(Uint8List hostKey) {
    final digest = sha256.convert(hostKey);
    return base64Encode(digest.bytes);
  }

  String _storageKey(String host, int port) => '$_prefix$host:$port';

  Future<String?> getStoredFingerprint(String host, int port) =>
      _store.read(_storageKey(host, port));

  Future<void> saveFingerprint(String host, int port, String fingerprint) =>
      _store.write(_storageKey(host, port), fingerprint);

  Future<void> removeFingerprint(String host, int port) =>
      _store.delete(_storageKey(host, port));

  /// Returns (matched, storedFingerprint):
  ///   matched == null  → no stored fingerprint (first connection)
  ///   matched == true  → fingerprint matches
  ///   matched == false → fingerprint mismatch (potential MITM)
  /// storedFingerprint is non-null when a fingerprint was previously stored.
  Future<(bool?, String?)> verify(
      String host, int port, Uint8List hostKey) async {
    final fingerprint = computeFingerprint(hostKey);
    final stored = await getStoredFingerprint(host, port);
    if (stored == null) return (null, null);
    return (stored == fingerprint, stored);
  }
}
