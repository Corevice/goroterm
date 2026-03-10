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

    final secureStorage = ref.read(secureStorageProvider);
    if (password != null && password.isNotEmpty) {
      await secureStorage.savePassword(id, password);
    }
    if (privateKeyPem != null && privateKeyPem.isNotEmpty) {
      await secureStorage.savePrivateKey(id, privateKeyPem);
    }

    ref.invalidateSelf();
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

    final secureStorage = ref.read(secureStorageProvider);
    if (password != null) {
      await secureStorage.savePassword(id, password);
    }
    if (privateKeyPem != null) {
      await secureStorage.savePrivateKey(id, privateKeyPem);
    }

    ref.invalidateSelf();
  }

  Future<void> deleteConnection(int id) async {
    final repo = ref.read(connectionRepositoryProvider);
    await repo.delete(id);
    final secureStorage = ref.read(secureStorageProvider);
    await secureStorage.deleteAllForConnection(id);
    ref.invalidateSelf();
  }
}

final connectionListProvider =
    AsyncNotifierProvider<ConnectionListNotifier, List<Connection>>(
  ConnectionListNotifier.new,
);
