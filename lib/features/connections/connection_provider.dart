import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/database.dart';
import '../../core/storage/connection_repository.dart';
import '../../core/storage/secure_storage.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('Database must be overridden in main');
});

final secureStorageProvider = Provider<SecureStorageService>((ref) {
  return SecureStorageService();
});

final connectionRepositoryProvider = Provider<ConnectionRepository>((ref) {
  return ConnectionRepository(
    db: ref.watch(databaseProvider),
    secureStorage: ref.watch(secureStorageProvider),
  );
});

final connectionsStreamProvider = StreamProvider<List<Connection>>((ref) {
  final repo = ref.watch(connectionRepositoryProvider);
  return repo.watchAll();
});

class ConnectionListNotifier extends AsyncNotifier<List<Connection>> {
  @override
  Future<List<Connection>> build() {
    return ref.watch(connectionRepositoryProvider).getAll();
  }

  Future<int> addConnection({
    required String label,
    required String host,
    required int port,
    required String username,
    required String authMethod,
    String? password,
    String? privateKeyPem,
  }) async {
    final repo = ref.read(connectionRepositoryProvider);
    final id = await repo.add(ConnectionsCompanion.insert(
      label: label,
      host: host,
      port: Value(port),
      username: username,
      authMethod: Value(authMethod),
    ));

    await _saveCredentials(id, password, privateKeyPem);
    return id;
  }

  Future<void> updateConnection({
    required int id,
    required String label,
    required String host,
    required int port,
    required String username,
    required String authMethod,
    String? password,
    String? privateKeyPem,
  }) async {
    final repo = ref.read(connectionRepositoryProvider);
    await repo.update(
      id,
      ConnectionsCompanion(
        label: Value(label),
        host: Value(host),
        port: Value(port),
        username: Value(username),
        authMethod: Value(authMethod),
      ),
    );

    await _saveCredentials(id, password, privateKeyPem);
  }

  /// Saves [password] and/or [privateKeyPem] to secure storage for the given
  /// connection [id], then invalidates this notifier to trigger a rebuild.
  /// Always calls [ref.invalidateSelf] even if the storage write fails, so that
  /// the connection list stays consistent with the database.
  ///
  /// Credential semantics:
  ///   - `null`  → not applicable (auth method doesn't use this credential);
  ///              leave secure storage unchanged.
  ///   - `''`    → user explicitly cleared the field; delete stored value.
  ///   - non-empty → save the new value.
  Future<void> _saveCredentials(
    int id,
    String? password,
    String? privateKeyPem,
  ) async {
    try {
      final secureStorage = ref.read(secureStorageProvider);
      if (password != null) {
        if (password.isNotEmpty) {
          await secureStorage.savePassword(id, password);
        } else {
          await secureStorage.deletePassword(id);
        }
      }
      if (privateKeyPem != null) {
        if (privateKeyPem.isNotEmpty) {
          await secureStorage.savePrivateKey(id, privateKeyPem);
        } else {
          await secureStorage.deletePrivateKey(id);
        }
      }
    } finally {
      ref.invalidateSelf();
    }
  }

  Future<void> deleteConnection(int id) async {
    // ConnectionRepository.delete() already cleans up secure storage
    // internally, so we do not call secureStorage.deleteAllForConnection here.
    // Always call invalidateSelf() so the UI list stays in sync even if the
    // database delete throws (mirrors the try/finally in _saveCredentials).
    try {
      await ref.read(connectionRepositoryProvider).delete(id);
    } finally {
      ref.invalidateSelf();
    }
  }
}

final connectionListProvider =
    AsyncNotifierProvider<ConnectionListNotifier, List<Connection>>(
  ConnectionListNotifier.new,
);
