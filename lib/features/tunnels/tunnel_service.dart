import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/utils/app_logger.dart';
import 'tunnel_models.dart';

/// Result of probing `docker ps` on the remote host.
class DockerProbeResult {
  const DockerProbeResult({
    required this.availability,
    required this.containers,
  });
  final DockerAvailability availability;
  final List<DockerContainer> containers;
}

/// Stateless helpers for the tunnels feature: docker probing + opening
/// individual tunnels. The provider owns lifecycle and persistence.
class TunnelService {
  TunnelService();

  /// Field separator for `docker ps --format`. Mirrors `TmuxNotifier._sep`.
  /// Avoids `\x1F` which some SSH exec channels mangle.
  static const _sep = '|||';

  /// Probe docker on the remote host and list running containers.
  ///
  /// Failure modes:
  ///   * `command not found`              → [DockerNotInstalled]
  ///   * exit != 0 + "permission denied"  → [DockerNoPermission]
  ///   * exit != 0 (other)                → [DockerNotInstalled] (best-effort
  ///     fallback so the UI surfaces "not installed" rather than a generic
  ///     error; the user can still add custom tunnels)
  Future<DockerProbeResult> listContainers(
    SshChannelManager channelManager,
  ) async {
    // Single round-trip: print version, then ps. We parse both sections.
    const marker = '=GoroDockerPs:';
    final cmd =
        "docker version --format '{{.Client.Version}}' 2>&1; "
        "echo '$marker'; "
        'docker ps --format '
        "'{{.ID}}$_sep{{.Names}}$_sep{{.Image}}$_sep{{.Status}}$_sep{{.Ports}}'";

    final (stdoutText, stderrText, exitCode) =
        await _runCommand(channelManager, cmd);
    final combined = stdoutText;

    final markerIdx = combined.indexOf(marker);
    final versionPart =
        markerIdx >= 0 ? combined.substring(0, markerIdx) : combined;
    final psPart = markerIdx >= 0 ? combined.substring(markerIdx + marker.length) : '';

    final versionLine = versionPart.trim();
    final stderrLower = stderrText.toLowerCase();
    final versionLower = versionLine.toLowerCase();

    final notInstalled = versionLower.contains('command not found') ||
        versionLower.contains('not found') ||
        stderrLower.contains('command not found');
    if (notInstalled) {
      return const DockerProbeResult(
        availability: DockerNotInstalled(),
        containers: [],
      );
    }

    final permDenied = versionLower.contains('permission denied') ||
        stderrLower.contains('permission denied') ||
        psPart.toLowerCase().contains('permission denied');
    if (permDenied) {
      return const DockerProbeResult(
        availability: DockerNoPermission(),
        containers: [],
      );
    }

    if (exitCode != null && exitCode != 0 && versionLine.isEmpty) {
      return const DockerProbeResult(
        availability: DockerNotInstalled(),
        containers: [],
      );
    }

    final containers = parseDockerPs(psPart);
    return DockerProbeResult(
      availability: DockerAvailable(version: versionLine),
      containers: containers,
    );
  }

  /// Parse the stdout of `docker ps --format '{{.ID}}|||{{.Names}}|||{{.Image}}|||{{.Status}}|||{{.Ports}}'`.
  ///
  /// Visible for testing.
  @visibleForTesting
  static List<DockerContainer> parseDockerPs(String output) {
    final containers = <DockerContainer>[];
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final parts = line.split(_sep);
      if (parts.length < 5) continue;
      containers.add(DockerContainer(
        id: parts[0],
        name: parts[1],
        image: parts[2],
        status: parts[3],
        ports: parsePortsField(parts[4]),
      ));
    }
    return containers;
  }

  /// Parse the `Ports` column of `docker ps`. Examples:
  /// * `0.0.0.0:8080->80/tcp, :::8080->80/tcp`
  /// * `0.0.0.0:5432->5432/tcp`
  /// * `9000/tcp` (exposed but not published — skipped)
  ///
  /// Returns deduplicated [PublishedPort] entries (IPv4 + IPv6 mappings of
  /// the same hostPort/containerPort/protocol collapse to one).
  @visibleForTesting
  static List<PublishedPort> parsePortsField(String field) {
    if (field.trim().isEmpty) return const [];
    final result = <PublishedPort>{};
    for (final raw in field.split(',')) {
      final entry = raw.trim();
      if (entry.isEmpty) continue;
      // Only mappings that include "->" are published.
      final arrowIdx = entry.indexOf('->');
      if (arrowIdx < 0) continue;
      final hostPart = entry.substring(0, arrowIdx);
      final containerPart = entry.substring(arrowIdx + 2);

      // hostPart: "host:port" or "[ipv6]:port" — extract trailing port.
      final hostColonIdx = hostPart.lastIndexOf(':');
      if (hostColonIdx < 0) continue;
      final hostPort = int.tryParse(hostPart.substring(hostColonIdx + 1));
      if (hostPort == null) continue;

      // containerPart: "port/protocol".
      final slashIdx = containerPart.indexOf('/');
      if (slashIdx < 0) continue;
      final containerPort = int.tryParse(containerPart.substring(0, slashIdx));
      final protocol = containerPart.substring(slashIdx + 1).trim().toLowerCase();
      if (containerPort == null || protocol.isEmpty) continue;

      result.add(PublishedPort(
        containerPort: containerPort,
        hostPort: hostPort,
        protocol: protocol,
      ));
    }
    return result.toList();
  }

  /// Open a tunnel. Returns a handle that owns the ServerSocket and all
  /// in-flight forwarded channels. [onUpdate] is invoked whenever the
  /// tunnel's status or stats change.
  Future<TunnelHandle> open({
    required SSHClient client,
    required TunnelConfig config,
    required TunnelUpdateCallback onUpdate,
  }) async {
    final preferred = config.preferredLocalPort ?? 0;
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, preferred);
    } catch (e) {
      onUpdate(TunnelStatus.error, null, const TunnelStats(), 'bind: $e');
      rethrow;
    }
    final handle = TunnelHandle._(
      client: client,
      config: config,
      server: server,
      onUpdate: onUpdate,
    );
    handle._start();
    return handle;
  }

  // ---- copied verbatim from tmux_provider._runCommand (kept private) ----
  Future<(String, String, int?)> _runCommand(
    SshChannelManager channelManager,
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final session = await channelManager.executeCommand(command);
    try {
      const decoder = Utf8Decoder(allowMalformed: true);
      final results = await Future.wait<String>([
        session.stdout.cast<List<int>>().transform(decoder).join(),
        session.stderr.cast<List<int>>().transform(decoder).join(),
      ]).timeout(timeout);
      try {
        await session.done.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // close-ACK slow; output is already collected.
      }
      return (results[0], results[1], session.exitCode);
    } finally {
      try {
        session.close();
      } catch (_) {}
    }
  }
}

typedef TunnelUpdateCallback = void Function(
  TunnelStatus status,
  int? localPort,
  TunnelStats stats,
  String? error,
);

/// Owns one [ServerSocket] and the SSH forward channels it spawns.
class TunnelHandle {
  TunnelHandle._({
    required SSHClient client,
    required this.config,
    required ServerSocket server,
    required TunnelUpdateCallback onUpdate,
  })  : _client = client,
        _server = server,
        _onUpdate = onUpdate;

  final TunnelConfig config;
  final SSHClient _client;
  ServerSocket? _server;
  StreamSubscription<Socket>? _acceptSub;
  final TunnelUpdateCallback _onUpdate;

  TunnelStats _stats = const TunnelStats();
  final Set<_Bridge> _bridges = {};
  bool _closed = false;

  int? get localPort => _server?.port;
  TunnelStats get stats => _stats;
  bool get isClosed => _closed;

  void _start() {
    _onUpdate(TunnelStatus.listening, _server!.port, _stats, null);
    _acceptSub = _server!.listen(
      _accept,
      onError: (Object e) {
        AppLogger.instance.log('tunnel ${config.label} accept error: $e');
        _onUpdate(TunnelStatus.error, _server?.port, _stats, 'accept: $e');
      },
    );
  }

  Future<void> _accept(Socket socket) async {
    if (_closed) {
      try {
        socket.destroy();
      } catch (_) {}
      return;
    }
    SSHForwardChannel channel;
    try {
      channel = await _client.forwardLocal(
        config.remoteHost,
        config.remotePort,
      );
    } catch (e) {
      AppLogger.instance.log(
        'tunnel ${config.label} forwardLocal failed: $e',
      );
      try {
        socket.destroy();
      } catch (_) {}
      _onUpdate(TunnelStatus.listening, _server?.port, _stats, 'forward: $e');
      return;
    }
    if (_closed) {
      try {
        socket.destroy();
      } catch (_) {}
      try {
        await channel.close();
      } catch (_) {}
      return;
    }
    final bridge = _Bridge(socket: socket, channel: channel, owner: this);
    _bridges.add(bridge);
    _stats = _stats.copyWith(
      activeConnections: _stats.activeConnections + 1,
      totalConnections: _stats.totalConnections + 1,
    );
    _onUpdate(TunnelStatus.listening, _server?.port, _stats, null);
    bridge.start();
  }

  void _onBridgeClosed(_Bridge b) {
    if (!_bridges.remove(b)) return;
    if (_closed) return;
    _stats = _stats.copyWith(
      activeConnections: (_stats.activeConnections - 1).clamp(0, 1 << 31),
    );
    _onUpdate(TunnelStatus.listening, _server?.port, _stats, null);
  }

  void _onBridgeBytes({int inBytes = 0, int outBytes = 0}) {
    if (_closed) return;
    if (inBytes == 0 && outBytes == 0) return;
    _stats = _stats.copyWith(
      bytesIn: _stats.bytesIn + inBytes,
      bytesOut: _stats.bytesOut + outBytes,
    );
    _onUpdate(TunnelStatus.listening, _server?.port, _stats, null);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _acceptSub?.cancel();
    _acceptSub = null;
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
    for (final b in [..._bridges]) {
      await b.dispose();
    }
    _bridges.clear();
    _stats = const TunnelStats();
    _onUpdate(TunnelStatus.stopped, null, _stats, null);
  }
}

/// Single client connection ↔ SSHForwardChannel pipe.
class _Bridge {
  _Bridge({
    required this.socket,
    required this.channel,
    required this.owner,
  });

  final Socket socket;
  final SSHForwardChannel channel;
  final TunnelHandle owner;

  StreamSubscription<Uint8List>? _socketSub;
  StreamSubscription<Uint8List>? _channelSub;
  bool _disposed = false;

  void start() {
    _socketSub = socket.listen(
      (data) {
        owner._onBridgeBytes(outBytes: data.length);
        try {
          channel.sink.add(data);
        } catch (_) {
          dispose();
        }
      },
      onError: (Object _) => dispose(),
      onDone: () {
        try {
          channel.sink.close();
        } catch (_) {}
      },
      cancelOnError: true,
    );

    _channelSub = channel.stream.listen(
      (data) {
        owner._onBridgeBytes(inBytes: data.length);
        try {
          socket.add(data);
        } catch (_) {
          dispose();
        }
      },
      onError: (Object _) => dispose(),
      onDone: () {
        try {
          socket.close();
        } catch (_) {}
      },
      cancelOnError: true,
    );

    // Final cleanup once channel.done resolves (both sides closed by SSH).
    channel.done.whenComplete(() => dispose());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _socketSub?.cancel();
    await _channelSub?.cancel();
    try {
      socket.destroy();
    } catch (_) {}
    try {
      await channel.close();
    } catch (_) {}
    owner._onBridgeClosed(this);
  }
}
