import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../terminal/session_manager.dart';
import 'tunnel_models.dart';
import 'tunnel_provider.dart';

/// Result returned from [AddTunnelDialog] — caller turns it into a
/// [TunnelConfig] (assigning a fresh id) before persisting.
class TunnelDraft {
  const TunnelDraft({
    required this.connectionId,
    required this.label,
    required this.remoteHost,
    required this.remotePort,
    this.preferredLocalPort,
    this.containerName,
  });

  final int connectionId;
  final String label;
  final String remoteHost;
  final int remotePort;
  final int? preferredLocalPort;
  final String? containerName;
}

class AddTunnelDialog extends ConsumerStatefulWidget {
  const AddTunnelDialog({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<AddTunnelDialog> createState() => _AddTunnelDialogState();
}

class _AddTunnelDialogState extends ConsumerState<AddTunnelDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  int? _resolveConnectionId() {
    final sessions = ref.read(sessionManagerProvider).sessions;
    for (final s in sessions) {
      if (s.sessionId == widget.sessionId) return s.connectionId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tunnelState = ref.watch(tunnelProvider(widget.sessionId)).valueOrNull;
    final connectionId = _resolveConnectionId();

    return Dialog(
      backgroundColor: Colors.grey[900],
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.add_link, color: Colors.white70),
                  const SizedBox(width: 12),
                  const Text(
                    'トンネルを追加',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tab,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white38,
              indicatorColor: Colors.lightBlueAccent,
              tabs: const [
                Tab(text: 'Containers'),
                Tab(text: 'Custom'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  _ContainerTab(
                    state: tunnelState,
                    connectionId: connectionId,
                    onPick: (draft) => Navigator.pop(context, draft),
                    onRefresh: () => ref
                        .read(tunnelProvider(widget.sessionId).notifier)
                        .refreshContainers(),
                  ),
                  _CustomTab(
                    connectionId: connectionId,
                    onAdd: (draft) => Navigator.pop(context, draft),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContainerTab extends StatelessWidget {
  const _ContainerTab({
    required this.state,
    required this.connectionId,
    required this.onPick,
    required this.onRefresh,
  });

  final TunnelStoreState? state;
  final int? connectionId;
  final void Function(TunnelDraft) onPick;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s == null || connectionId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final docker = s.dockerAvailability;
    if (docker is DockerNotInstalled) {
      return const _Notice(
        icon: Icons.info_outline,
        text: 'Docker は検出されませんでした。\nCustom タブから任意宛先のトンネルを作成できます。',
      );
    }
    if (docker is DockerNoPermission) {
      return const _Notice(
        icon: Icons.lock_outline,
        text: 'SSH ユーザーに Docker 権限がありません。\n'
            'サーバー側で `sudo usermod -aG docker \$USER` してから再ログインしてください。',
      );
    }
    if (s.containersLoading && s.containers.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (s.containers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox, color: Colors.white24, size: 56),
            const SizedBox(height: 12),
            const Text(
              '稼働中のコンテナはありません',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 4),
            const Text(
              '`-p` で公開ポートのある docker run / compose があれば\n'
              'ここに表示されます。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('再取得'),
              onPressed: onRefresh,
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final c in s.containers)
          _ContainerCard(
            container: c,
            connectionId: connectionId!,
            onPick: onPick,
          ),
      ],
    );
  }
}

class _ContainerCard extends StatelessWidget {
  const _ContainerCard({
    required this.container,
    required this.connectionId,
    required this.onPick,
  });

  final DockerContainer container;
  final int connectionId;
  final void Function(TunnelDraft) onPick;

  @override
  Widget build(BuildContext context) {
    final ports = container.tcpPublishedPorts.toList();
    return Card(
      color: Colors.grey[850],
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              container.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              container.image,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            if (ports.isEmpty)
              const Text(
                '公開ポートなし',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in ports)
                    ActionChip(
                      backgroundColor: Colors.blueGrey[800],
                      label: Text(
                        '${p.hostPort}→${p.containerPort}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                      onPressed: () => onPick(TunnelDraft(
                        connectionId: connectionId,
                        label: '${container.name}:${p.containerPort}',
                        remoteHost: '127.0.0.1',
                        remotePort: p.hostPort,
                        containerName: container.name,
                      )),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _CustomTab extends StatefulWidget {
  const _CustomTab({required this.connectionId, required this.onAdd});

  final int? connectionId;
  final void Function(TunnelDraft) onAdd;

  @override
  State<_CustomTab> createState() => _CustomTabState();
}

class _CustomTabState extends State<_CustomTab> {
  final _formKey = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController();
  final _localPort = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    _localPort.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.connectionId == null) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    widget.onAdd(TunnelDraft(
      connectionId: widget.connectionId!,
      label: _label.text.trim().isEmpty
          ? '${_host.text.trim()}:${_port.text.trim()}'
          : _label.text.trim(),
      remoteHost: _host.text.trim(),
      remotePort: int.parse(_port.text.trim()),
      preferredLocalPort: _localPort.text.trim().isEmpty
          ? null
          : int.tryParse(_localPort.text.trim()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(
              controller: _label,
              label: 'ラベル（任意）',
              hint: 'My Postgres',
            ),
            _field(
              controller: _host,
              label: 'ホスト',
              hint: 'SSH サーバーから見たホスト名 / IP',
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'ホストを入力してください'
                  : null,
            ),
            _field(
              controller: _port,
              label: 'リモートポート',
              hint: '例: 5432',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (v) {
                final n = int.tryParse(v?.trim() ?? '');
                if (n == null || n < 1 || n > 65535) return '1–65535';
                return null;
              },
            ),
            _field(
              controller: _localPort,
              label: 'ローカルポート（空欄＝自動）',
              hint: '例: 18080',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                final n = int.tryParse(v.trim());
                if (n == null || n < 1 || n > 65535) return '1–65535';
                return null;
              },
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: widget.connectionId == null ? null : _submit,
                child: const Text('追加'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        validator: validator,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: Colors.white70),
          hintStyle: const TextStyle(color: Colors.white24),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.grey[700]!),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: Colors.lightBlueAccent),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white24, size: 48),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
