// Merged from: tunnel_repository_test.dart, tunnel_service_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:terminal_ssh_app/core/storage/database.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_channel_manager.dart';
import 'package:terminal_ssh_app/features/tunnels/tunnel_models.dart';
import 'package:terminal_ssh_app/features/tunnels/tunnel_repository.dart';
import 'package:terminal_ssh_app/features/tunnels/tunnel_service.dart';

class _MockSshChannelManager extends Mock implements SshChannelManager {}

class _MockSSHSession extends Mock implements SSHSession {}

_MockSSHSession _makeSession({
  List<int> stdout = const [],
  List<int> stderr = const [],
  int? exitCode = 0,
}) {
  final s = _MockSSHSession();
  when(() => s.stdout).thenAnswer(
    (_) => stdout.isEmpty
        ? const Stream<Uint8List>.empty()
        : Stream.value(Uint8List.fromList(stdout)),
  );
  when(() => s.stderr).thenAnswer(
    (_) => stderr.isEmpty
        ? const Stream<Uint8List>.empty()
        : Stream.value(Uint8List.fromList(stderr)),
  );
  when(() => s.done).thenAnswer((_) => Future<void>.value());
  when(() => s.exitCode).thenReturn(exitCode);
  when(() => s.close()).thenReturn(null);
  return s;
}

void main() {
  // =====================================================================
  // tunnel_repository.dart
  // =====================================================================
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

  // =====================================================================
  // tunnel_service.dart
  // =====================================================================
  group('parsePortsField', () {
    test('parses single ipv4 mapping', () {
      final ports = TunnelService.parsePortsField('0.0.0.0:8080->80/tcp');
      expect(ports.length, 1);
      expect(ports[0].hostPort, 8080);
      expect(ports[0].containerPort, 80);
      expect(ports[0].protocol, 'tcp');
    });

    test('dedupes ipv4+ipv6 mappings of same port', () {
      final ports = TunnelService.parsePortsField(
        '0.0.0.0:8080->80/tcp, :::8080->80/tcp',
      );
      expect(ports.length, 1);
      expect(ports[0].hostPort, 8080);
    });

    test('parses multiple distinct mappings', () {
      final ports = TunnelService.parsePortsField(
        '0.0.0.0:5432->5432/tcp, 0.0.0.0:6379->6379/tcp',
      );
      expect(ports.length, 2);
      expect(ports.map((p) => p.hostPort).toSet(), {5432, 6379});
    });

    test('skips exposed-only entries (no arrow)', () {
      final ports = TunnelService.parsePortsField('9000/tcp');
      expect(ports, isEmpty);
    });

    test('skips invalid entries gracefully', () {
      final ports = TunnelService.parsePortsField('garbage, 0.0.0.0:80->/tcp');
      expect(ports, isEmpty);
    });

    test('returns empty for empty field', () {
      expect(TunnelService.parsePortsField(''), isEmpty);
      expect(TunnelService.parsePortsField('   '), isEmpty);
    });

    test('handles udp protocol but marks isTcp false', () {
      final ports =
          TunnelService.parsePortsField('0.0.0.0:53->53/udp');
      expect(ports.length, 1);
      expect(ports[0].isTcp, isFalse);
    });
  });

  group('parseDockerPs', () {
    test('parses one container with ports', () {
      const out = 'abc123|||my-pg|||postgres:16|||Up 2 hours|||0.0.0.0:5432->5432/tcp\n';
      final containers = TunnelService.parseDockerPs(out);
      expect(containers.length, 1);
      expect(containers[0].id, 'abc123');
      expect(containers[0].name, 'my-pg');
      expect(containers[0].image, 'postgres:16');
      expect(containers[0].status, 'Up 2 hours');
      expect(containers[0].ports.length, 1);
      expect(containers[0].ports[0].hostPort, 5432);
    });

    test('parses container with empty ports column', () {
      const out = 'def456|||sidecar|||alpine|||Up 1 hour|||\n';
      final containers = TunnelService.parseDockerPs(out);
      expect(containers.length, 1);
      expect(containers[0].ports, isEmpty);
    });

    test('parses multiple containers', () {
      const out = 'a|||one|||img|||Up|||0.0.0.0:80->80/tcp\n'
          'b|||two|||img|||Up|||0.0.0.0:81->81/tcp\n';
      final containers = TunnelService.parseDockerPs(out);
      expect(containers.length, 2);
    });

    test('skips malformed lines', () {
      const out = 'a|||one|||img|||Up\n'
          'b|||two|||img|||Up|||\n';
      final containers = TunnelService.parseDockerPs(out);
      expect(containers.length, 1);
      expect(containers[0].name, 'two');
    });

    test('returns empty for empty output', () {
      expect(TunnelService.parseDockerPs(''), isEmpty);
      expect(TunnelService.parseDockerPs('\n\n'), isEmpty);
    });
  });

  group('TunnelService.listContainers', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('reports DockerNotInstalled on command-not-found', () async {
      final mgr = _MockSshChannelManager();
      final session = _makeSession(
        stdout: utf8.encode(
          'bash: docker: command not found\n=GoroDockerPs:\n',
        ),
        exitCode: 127,
      );
      when(() => mgr.executeCommand(any())).thenAnswer((_) async => session);

      final result = await TunnelService().listContainers(mgr);
      expect(result.availability, isA<DockerNotInstalled>());
      expect(result.containers, isEmpty);
    });

    test('reports DockerNoPermission when ps reports permission denied',
        () async {
      final mgr = _MockSshChannelManager();
      final session = _makeSession(
        stdout: utf8.encode(
          '24.0.7\n=GoroDockerPs:\n'
          'permission denied while trying to connect to the Docker daemon\n',
        ),
        exitCode: 1,
      );
      when(() => mgr.executeCommand(any())).thenAnswer((_) async => session);

      final result = await TunnelService().listContainers(mgr);
      expect(result.availability, isA<DockerNoPermission>());
    });

    test('reports DockerAvailable + parses containers', () async {
      final mgr = _MockSshChannelManager();
      final session = _makeSession(
        stdout: utf8.encode(
          '24.0.7\n=GoroDockerPs:\n'
          'abc|||pg|||postgres|||Up|||0.0.0.0:5432->5432/tcp\n',
        ),
        exitCode: 0,
      );
      when(() => mgr.executeCommand(any())).thenAnswer((_) async => session);

      final result = await TunnelService().listContainers(mgr);
      expect(result.availability, isA<DockerAvailable>());
      expect((result.availability as DockerAvailable).version, '24.0.7');
      expect(result.containers.length, 1);
      expect(result.containers[0].name, 'pg');
    });

    test('handles no containers running gracefully', () async {
      final mgr = _MockSshChannelManager();
      final session = _makeSession(
        stdout: utf8.encode('24.0.7\n=GoroDockerPs:\n'),
        exitCode: 0,
      );
      when(() => mgr.executeCommand(any())).thenAnswer((_) async => session);

      final result = await TunnelService().listContainers(mgr);
      expect(result.availability, isA<DockerAvailable>());
      expect(result.containers, isEmpty);
    });
  });
}
