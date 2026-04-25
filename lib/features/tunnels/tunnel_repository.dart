import 'package:drift/drift.dart';

import '../../core/storage/database.dart';
import 'tunnel_models.dart';

/// Persistence layer for [TunnelConfig]. One row per saved tunnel,
/// scoped to a [Connections] row via foreign key cascade.
class TunnelRepository {
  TunnelRepository({required this.db});

  final AppDatabase db;

  Future<List<TunnelConfig>> getByConnection(int connectionId) async {
    final rows = await (db.select(db.portTunnels)
          ..where((t) => t.connectionId.equals(connectionId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)
          ]))
        .get();
    return rows.map(_fromRow).toList();
  }

  Future<void> insert(TunnelConfig config) async {
    await db.into(db.portTunnels).insert(
          PortTunnelsCompanion.insert(
            id: config.id,
            connectionId: config.connectionId,
            label: config.label,
            remoteHost: config.remoteHost,
            remotePort: config.remotePort,
            preferredLocalPort: Value(config.preferredLocalPort),
            containerName: Value(config.containerName),
          ),
        );
  }

  Future<void> deleteById(String id) async {
    await (db.delete(db.portTunnels)..where((t) => t.id.equals(id))).go();
  }

  TunnelConfig _fromRow(PortTunnel row) => TunnelConfig(
        id: row.id,
        connectionId: row.connectionId,
        label: row.label,
        remoteHost: row.remoteHost,
        remotePort: row.remotePort,
        preferredLocalPort: row.preferredLocalPort,
        containerName: row.containerName,
      );
}
