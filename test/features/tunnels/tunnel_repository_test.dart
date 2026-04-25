import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/core/storage/database.dart';
import 'package:terminal_ssh_app/features/tunnels/tunnel_models.dart';
import 'package:terminal_ssh_app/features/tunnels/tunnel_repository.dart';

void main() {
  group('TunnelRepository', () {
    late AppDatabase db;
    late TunnelRepository repo;
    late int connectionId;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = TunnelRepository(db: db);
      connectionId = await db.into(db.connections).insert(
            ConnectionsCompanion.insert(
              label: 'test',
              host: 'localhost',
              username: 'me',
            ),
          );
    });

    tearDown(() async {
      await db.close();
    });

    test('insert + getByConnection round trip', () async {
      final cfg = TunnelConfig(
        id: 't-1',
        connectionId: connectionId,
        label: 'pg',
        remoteHost: '127.0.0.1',
        remotePort: 5432,
        preferredLocalPort: 15432,
        containerName: 'my-pg',
      );
      await repo.insert(cfg);
      final loaded = await repo.getByConnection(connectionId);
      expect(loaded.length, 1);
      expect(loaded[0].id, 't-1');
      expect(loaded[0].label, 'pg');
      expect(loaded[0].remoteHost, '127.0.0.1');
      expect(loaded[0].remotePort, 5432);
      expect(loaded[0].preferredLocalPort, 15432);
      expect(loaded[0].containerName, 'my-pg');
    });

    test('getByConnection returns empty for unknown connection', () async {
      final loaded = await repo.getByConnection(999);
      expect(loaded, isEmpty);
    });

    test('deleteById removes the row', () async {
      await repo.insert(TunnelConfig(
        id: 't-1',
        connectionId: connectionId,
        label: 'pg',
        remoteHost: '127.0.0.1',
        remotePort: 5432,
      ));
      await repo.deleteById('t-1');
      final loaded = await repo.getByConnection(connectionId);
      expect(loaded, isEmpty);
    });

    test('cascades when parent connection is deleted', () async {
      await repo.insert(TunnelConfig(
        id: 't-1',
        connectionId: connectionId,
        label: 'pg',
        remoteHost: '127.0.0.1',
        remotePort: 5432,
      ));
      await (db.delete(db.connections)
            ..where((t) => t.id.equals(connectionId)))
          .go();
      final loaded = await repo.getByConnection(connectionId);
      expect(loaded, isEmpty);
    });
  });
}
