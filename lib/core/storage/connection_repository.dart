import 'package:drift/drift.dart';

import 'database.dart';
import 'secure_storage.dart';

class ConnectionRepository {
  ConnectionRepository({
    required this.db,
    required this.secureStorage,
  });

  final AppDatabase db;
  final SecureStorageService secureStorage;

  Future<List<Connection>> getAll() {
    return (db.select(db.connections)
          ..orderBy([
            (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)
          ]))
        .get();
  }

  Future<Connection?> getById(int id) {
    return (db.select(db.connections)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<int> add(ConnectionsCompanion entry) {
    return db.into(db.connections).insert(entry);
  }

  Future<bool> update(int id, ConnectionsCompanion entry) {
    return (db.update(db.connections)..where((t) => t.id.equals(id)))
        .write(entry)
        .then((rows) => rows > 0);
  }

  Future<int> delete(int id) async {
    await secureStorage.deleteAllForConnection(id);
    return (db.delete(db.connections)..where((t) => t.id.equals(id))).go();
  }

  Stream<List<Connection>> watchAll() {
    return (db.select(db.connections)
          ..orderBy([
            (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)
          ]))
        .watch();
  }
}
