import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'add_tunnel_dialog.dart';
import 'tunnel_models.dart';
import 'tunnel_provider.dart';

class TunnelManagerScreen extends ConsumerStatefulWidget {
  const TunnelManagerScreen({
    super.key,
    required this.sessionId,
  });

  final String sessionId;

  @override
  ConsumerState<TunnelManagerScreen> createState() =>
      _TunnelManagerScreenState();
}

class _TunnelManagerScreenState extends ConsumerState<TunnelManagerScreen> {
  AsyncValue<TunnelStoreState> _state = const AsyncLoading();
  ProviderSubscription<AsyncValue<TunnelStoreState>>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sub = ref.listenManual(
        tunnelProvider(widget.sessionId),
        (_, next) {
          if (mounted) setState(() => _state = next);
        },
        fireImmediately: true,
      );
    });
  }

  @override
  void dispose() {
    _sub?.close();
    super.dispose();
  }

  Future<void> _addTunnel() async {
    final result = await showDialog<TunnelDraft>(
      context: context,
      builder: (_) => AddTunnelDialog(sessionId: widget.sessionId),
    );
    if (result == null || !mounted) return;
    final config = TunnelConfig(
      id: TunnelNotifier.newId(),
      connectionId: result.connectionId,
      label: result.label,
      remoteHost: result.remoteHost,
      remotePort: result.remotePort,
      preferredLocalPort: result.preferredLocalPort,
      containerName: result.containerName,
    );
    await ref
        .read(tunnelProvider(widget.sessionId).notifier)
        .addTunnel(config);
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Container(
      color: Colors.grey[900],
      child: Column(
        children: [
          _Header(
            onRefresh: () => ref
                .read(tunnelProvider(widget.sessionId).notifier)
                .refreshContainers(),
          ),
          Expanded(
            child: state.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text('Error: $e',
                    style: const TextStyle(color: Colors.white70)),
              ),
              data: (data) => _Body(
                state: data,
                onAdd: _addTunnel,
                onDelete: (id) => ref
                    .read(tunnelProvider(widget.sessionId).notifier)
                    .removeTunnel(id),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onRefresh});
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey[800]!)),
      ),
      child: Row(
        children: [
          const Icon(Icons.swap_horiz, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          const Text(
            'Port Tunnels',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'コンテナ一覧を更新',
            icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.state,
    required this.onAdd,
    required this.onDelete,
  });

  final TunnelStoreState state;
  final VoidCallback onAdd;
  final void Function(String tunnelId) onDelete;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (state.tunnels.isEmpty)
          _EmptyState(state: state, onAdd: onAdd)
        else
          ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            children: [
              for (final t in state.tunnels)
                _TunnelCard(
                  state: t,
                  onDelete: () => onDelete(t.config.id),
                ),
            ],
          ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: onAdd,
            backgroundColor: Colors.blueGrey[700],
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add),
            label: const Text('Add Tunnel'),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.state, required this.onAdd});

  final TunnelStoreState state;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final docker = state.dockerAvailability;
    String hint;
    if (docker is DockerAvailable) {
      hint = '右下の「+ Add Tunnel」からコンテナまたは任意ホストを選んでトンネルを開きます。';
    } else if (docker is DockerNoPermission) {
      hint = 'Docker は検出されましたが SSH ユーザーに権限がありません。\nカスタム宛先のトンネルは作成できます。';
    } else {
      hint = 'Docker は未検出です。\nカスタム宛先のトンネルは作成できます。';
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cable, color: Colors.white24, size: 56),
            const SizedBox(height: 16),
            const Text(
              'まだトンネルがありません',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _TunnelCard extends StatelessWidget {
  const _TunnelCard({required this.state, required this.onDelete});

  final TunnelState state;
  final VoidCallback onDelete;

  Color get _statusColor {
    switch (state.status) {
      case TunnelStatus.listening:
        return Colors.greenAccent;
      case TunnelStatus.binding:
        return Colors.amberAccent;
      case TunnelStatus.error:
        return Colors.redAccent;
      case TunnelStatus.stopped:
        return Colors.white24;
    }
  }

  String get _localText {
    final port = state.localPort;
    if (port == null) return 'localhost:—';
    return 'localhost:$port';
  }

  String get _targetText =>
      '${state.config.remoteHost}:${state.config.remotePort}';

  String get _statsText {
    final s = state.stats;
    return '${s.activeConnections} active · ${_human(s.bytesIn)} ↓ / ${_human(s.bytesOut)} ↑';
  }

  static String _human(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)}MB';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey[850],
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: state.localPort == null
            ? null
            : () async {
                await Clipboard.setData(
                  ClipboardData(text: _localText),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(seconds: 1),
                      content: Text('$_localText をコピーしました'),
                    ),
                  );
                }
              },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.config.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$_localText  →  $_targetText',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.error ?? _statsText,
                      style: TextStyle(
                        color: state.error != null
                            ? Colors.redAccent
                            : Colors.white38,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '削除',
                icon: const Icon(
                  Icons.delete_outline,
                  color: Colors.white54,
                  size: 20,
                ),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: Colors.grey[900],
                      title: const Text(
                        'トンネルを削除',
                        style: TextStyle(color: Colors.white),
                      ),
                      content: Text(
                        '${state.config.label} を削除しますか？',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('キャンセル'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text(
                            '削除',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) onDelete();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
