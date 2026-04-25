import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/utils/app_logger.dart';
import '../connections/connection_provider.dart';
import '../terminal/session_manager.dart';
import 'tunnel_models.dart';
import 'tunnel_repository.dart';
import 'tunnel_service.dart';

final tunnelRepositoryProvider = Provider<TunnelRepository>((ref) {
  return TunnelRepository(db: ref.watch(databaseProvider));
});

final tunnelServiceProvider = Provider<TunnelService>((ref) => TunnelService());

class TunnelNotifier extends FamilyAsyncNotifier<TunnelStoreState, String> {
  SshChannelManager? _channelManager;
  final Map<String, TunnelHandle> _handles = {};
  bool _isOperating = false;

  /// Look up the drift connectionId for our sessionId.
  /// Returns null if the session has been removed.
  int? _resolveConnectionId() {
    final sessions = ref.read(sessionManagerProvider).sessions;
    for (final s in sessions) {
      if (s.sessionId == arg) return s.connectionId;
    }
    return null;
  }

  TunnelService get _service => ref.read(tunnelServiceProvider);
  TunnelRepository get _repo => ref.read(tunnelRepositoryProvider);

  /// Called by TerminalScreen when the SSH channelManager changes.
  void setChannelManager(SshChannelManager? channelManager) {
    if (_channelManager == channelManager) return;
    _channelManager = channelManager;
    if (channelManager != null) {
      _initialize(channelManager);
    } else {
      _stopAllTunnels();
      state = AsyncData(const TunnelStoreState());
    }
  }

  Future<void> _initialize(SshChannelManager channelManager) async {
    state = AsyncData(state.valueOrNull ?? const TunnelStoreState());
    await refreshContainers();
    if (_channelManager != channelManager) return; // stale
    await _restorePersistedTunnels();
  }

  /// Refresh `docker ps` results.
  Future<void> refreshContainers() async {
    final channelManager = _channelManager;
    if (channelManager == null) return;
    final current = state.valueOrNull ?? const TunnelStoreState();
    state = AsyncData(current.copyWith(
      containersLoading: true,
      containersError: null,
    ));
    try {
      final result = await _service.listContainers(channelManager);
      if (_channelManager != channelManager) return; // stale
      _patch((s) => s.copyWith(
            dockerAvailability: result.availability,
            containers: result.containers,
            containersLoading: false,
          ));
    } catch (e, st) {
      AppLogger.instance.log('refreshContainers failed: $e\n$st');
      if (_channelManager != channelManager) return;
      _patch((s) => s.copyWith(
            containersLoading: false,
            containersError: e.toString(),
          ));
    }
  }

  Future<void> _restorePersistedTunnels() async {
    final connectionId = _resolveConnectionId();
    if (connectionId == null) return;
    final List<TunnelConfig> persisted;
    try {
      persisted = await _repo.getByConnection(connectionId);
    } catch (e) {
      AppLogger.instance.log('tunnel repo read failed: $e');
      return;
    }
    for (final cfg in persisted) {
      // Skip if already running (e.g. duplicate restore on rapid reconnect).
      if (_handles.containsKey(cfg.id)) continue;
      await _startTunnel(cfg, persistFirst: false);
    }
  }

  /// Add and start a new tunnel. The config is persisted before the tunnel
  /// starts so it survives a restart even if `forwardLocal` is slow.
  Future<void> addTunnel(TunnelConfig config) async {
    if (_isOperating) return;
    _isOperating = true;
    try {
      await _startTunnel(config, persistFirst: true);
    } finally {
      _isOperating = false;
    }
  }

  /// Stop and forget a tunnel. Safe to call multiple times.
  Future<void> removeTunnel(String tunnelId) async {
    final handle = _handles.remove(tunnelId);
    if (handle != null) {
      try {
        await handle.close();
      } catch (_) {}
    }
    try {
      await _repo.deleteById(tunnelId);
    } catch (_) {}
    _patch((s) => s.copyWith(
          tunnels: s.tunnels.where((t) => t.config.id != tunnelId).toList(),
        ));
  }

  Future<void> _startTunnel(
    TunnelConfig config, {
    required bool persistFirst,
  }) async {
    final channelManager = _channelManager;
    if (channelManager == null) return;

    if (persistFirst) {
      try {
        await _repo.insert(config);
      } catch (e) {
        AppLogger.instance.log('tunnel persist failed: $e');
        return;
      }
    }

    _patch((s) {
      final filtered = s.tunnels.where((t) => t.config.id != config.id).toList();
      filtered.add(TunnelState(config: config));
      return s.copyWith(tunnels: filtered);
    });

    try {
      final handle = await _service.open(
        client: channelManager.client,
        config: config,
        onUpdate: (status, localPort, stats, error) {
          _patch((s) => s.copyWith(
                tunnels: [
                  for (final t in s.tunnels)
                    if (t.config.id == config.id)
                      t.copyWith(
                        status: status,
                        localPort: localPort,
                        stats: stats,
                        error: error,
                      )
                    else
                      t,
                ],
              ));
        },
      );
      _handles[config.id] = handle;
    } catch (e) {
      AppLogger.instance.log('tunnel ${config.label} open failed: $e');
      _patch((s) => s.copyWith(
            tunnels: [
              for (final t in s.tunnels)
                if (t.config.id == config.id)
                  t.copyWith(status: TunnelStatus.error, error: e.toString())
                else
                  t,
            ],
          ));
    }
  }

  void _stopAllTunnels() {
    for (final h in _handles.values) {
      // fire-and-forget close (notifier may be torn down soon).
      // ignore: discarded_futures
      h.close();
    }
    _handles.clear();
    _patch((s) => s.copyWith(
          tunnels: [
            for (final t in s.tunnels)
              t.copyWith(
                status: TunnelStatus.stopped,
                localPort: null,
                stats: const TunnelStats(),
              ),
          ],
          containers: const [],
        ));
  }

  void _patch(TunnelStoreState Function(TunnelStoreState) updater) {
    final current = state.valueOrNull ?? const TunnelStoreState();
    state = AsyncData(updater(current));
  }

  /// Generate a fresh UUID-ish ID for a new tunnel config.
  static String newId() {
    final r = Random.secure();
    final bytes = List<int>.generate(8, (_) => r.nextInt(256));
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 't-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-$hex';
  }

  @override
  Future<TunnelStoreState> build(String arg) async {
    ref.keepAlive();
    ref.onDispose(_stopAllTunnels);
    return const TunnelStoreState();
  }

  @visibleForTesting
  void setStateForTesting(TunnelStoreState value) {
    state = AsyncData(value);
  }

  @visibleForTesting
  Map<String, TunnelHandle> get handlesForTesting => _handles;
}

final tunnelProvider =
    AsyncNotifierProvider.family<TunnelNotifier, TunnelStoreState, String>(
  TunnelNotifier.new,
);
