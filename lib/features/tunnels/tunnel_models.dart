import 'package:flutter/foundation.dart';

/// Lifecycle status of a single tunnel.
enum TunnelStatus {
  /// Initial state — provider is starting the tunnel.
  binding,

  /// ServerSocket is bound and accepting incoming connections.
  listening,

  /// Tunnel failed to bind or the SSH side errored fatally.
  error,

  /// Tunnel was stopped by the user; ServerSocket is closed.
  stopped,
}

/// A single published port on a Docker container (Docker → host mapping).
@immutable
class PublishedPort {
  const PublishedPort({
    required this.containerPort,
    required this.hostPort,
    required this.protocol,
  });

  final int containerPort;
  final int hostPort;

  /// `tcp` or `udp` (only `tcp` is tunnel-able).
  final String protocol;

  bool get isTcp => protocol == 'tcp';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PublishedPort &&
          containerPort == other.containerPort &&
          hostPort == other.hostPort &&
          protocol == other.protocol;

  @override
  int get hashCode => Object.hash(containerPort, hostPort, protocol);

  @override
  String toString() => '$hostPort->$containerPort/$protocol';
}

/// A running Docker container as reported by `docker ps`.
@immutable
class DockerContainer {
  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.status,
    required this.ports,
  });

  final String id;
  final String name;
  final String image;
  final String status;
  final List<PublishedPort> ports;

  /// TCP ports that are published to the host (the only ones we can tunnel
  /// against today).
  Iterable<PublishedPort> get tcpPublishedPorts =>
      ports.where((p) => p.isTcp);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DockerContainer &&
          id == other.id &&
          name == other.name &&
          image == other.image &&
          status == other.status &&
          listEquals(ports, other.ports);

  @override
  int get hashCode => Object.hash(id, name, image, status, Object.hashAll(ports));
}

/// Whether `docker ps` is usable on the remote host.
sealed class DockerAvailability {
  const DockerAvailability();
}

class DockerAvailable extends DockerAvailability {
  const DockerAvailable({required this.version});
  final String version;
}

class DockerNotInstalled extends DockerAvailability {
  const DockerNotInstalled();
}

/// Docker is installed but the SSH user lacks access (typical: not in
/// the `docker` group → `permission denied` on the socket).
class DockerNoPermission extends DockerAvailability {
  const DockerNoPermission();
}

/// Persisted tunnel configuration (stored in drift, recreated on reconnect).
@immutable
class TunnelConfig {
  const TunnelConfig({
    required this.id,
    required this.connectionId,
    required this.label,
    required this.remoteHost,
    required this.remotePort,
    this.preferredLocalPort,
    this.containerName,
  });

  /// Stable client-side UUID. Used both as drift PK and provider key.
  final String id;

  /// drift `Connections.id` this tunnel belongs to.
  final int connectionId;

  /// Human-readable label shown in the list.
  final String label;

  /// Hostname/IP reachable from the SSH server. For published Docker ports
  /// this is `127.0.0.1`; for custom destinations, whatever the user typed.
  final String remoteHost;

  final int remotePort;

  /// Desired loopback port on the device. `null` = pick any free port.
  final int? preferredLocalPort;

  /// Optional: source Docker container name (informational only).
  final String? containerName;

  TunnelConfig copyWith({
    String? label,
    String? remoteHost,
    int? remotePort,
    int? preferredLocalPort,
    String? containerName,
  }) =>
      TunnelConfig(
        id: id,
        connectionId: connectionId,
        label: label ?? this.label,
        remoteHost: remoteHost ?? this.remoteHost,
        remotePort: remotePort ?? this.remotePort,
        preferredLocalPort: preferredLocalPort ?? this.preferredLocalPort,
        containerName: containerName ?? this.containerName,
      );
}

/// Live counters for a tunnel.
@immutable
class TunnelStats {
  const TunnelStats({
    this.activeConnections = 0,
    this.totalConnections = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
  });

  final int activeConnections;
  final int totalConnections;
  final int bytesIn;
  final int bytesOut;

  TunnelStats copyWith({
    int? activeConnections,
    int? totalConnections,
    int? bytesIn,
    int? bytesOut,
  }) =>
      TunnelStats(
        activeConnections: activeConnections ?? this.activeConnections,
        totalConnections: totalConnections ?? this.totalConnections,
        bytesIn: bytesIn ?? this.bytesIn,
        bytesOut: bytesOut ?? this.bytesOut,
      );
}

/// Runtime state for one tunnel, surfaced to the UI.
@immutable
class TunnelState {
  const TunnelState({
    required this.config,
    this.status = TunnelStatus.binding,
    this.localPort,
    this.error,
    this.stats = const TunnelStats(),
  });

  final TunnelConfig config;
  final TunnelStatus status;
  final int? localPort;
  final String? error;
  final TunnelStats stats;

  TunnelState copyWith({
    TunnelConfig? config,
    TunnelStatus? status,
    int? localPort,
    Object? error = _noChange,
    TunnelStats? stats,
  }) =>
      TunnelState(
        config: config ?? this.config,
        status: status ?? this.status,
        localPort: localPort ?? this.localPort,
        error: identical(error, _noChange) ? this.error : error as String?,
        stats: stats ?? this.stats,
      );

  static const _noChange = Object();
}

/// Aggregate state for the tunnels feature, per terminal session.
@immutable
class TunnelStoreState {
  const TunnelStoreState({
    this.dockerAvailability = const DockerNotInstalled(),
    this.containers = const [],
    this.tunnels = const [],
    this.containersLoading = false,
    this.containersError,
  });

  final DockerAvailability dockerAvailability;
  final List<DockerContainer> containers;
  final List<TunnelState> tunnels;
  final bool containersLoading;
  final String? containersError;

  TunnelStoreState copyWith({
    DockerAvailability? dockerAvailability,
    List<DockerContainer>? containers,
    List<TunnelState>? tunnels,
    bool? containersLoading,
    Object? containersError = _noChange,
  }) =>
      TunnelStoreState(
        dockerAvailability: dockerAvailability ?? this.dockerAvailability,
        containers: containers ?? this.containers,
        tunnels: tunnels ?? this.tunnels,
        containersLoading: containersLoading ?? this.containersLoading,
        containersError: identical(containersError, _noChange)
            ? this.containersError
            : containersError as String?,
      );

  static const _noChange = Object();
}
