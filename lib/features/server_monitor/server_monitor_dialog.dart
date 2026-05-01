import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/utils/format_utils.dart';
import '../terminal/terminal_connection_provider.dart';
import 'server_info_parser.dart';

/// Process IDs and command names that are critical and should not be killed.
const _kCriticalPids = {0, 1};
const _kCriticalCommands = {
  'init', 'systemd', 'kthreadd', 'rcu_gp', 'rcu_par_gp', 'slub_flushwq',
  'netns', 'kworker', 'kswapd', 'kcompactd', 'crypto', 'kblockd', 'ata_sff',
  'md', 'edac-poller', 'watchdogd', 'khungtaskd', 'oom_reaper', 'writeback',
  'kcompactd0', 'kintegrityd', 'blkcg_punt_bio',
  'tpm_dev_wq', 'kworker/u', 'migration', 'cpuhp', 'calibration',
};

bool _isCriticalProcess(ProcessInfo p) {
  if (_kCriticalPids.contains(p.pid)) return true;
  final cmd = p.command.split('/').last.split(' ').first;
  if (_kCriticalCommands.contains(cmd)) return true;
  return false;
}

/// サーバーリソースモニター。SSH 経由でシステム情報を取得しボトムシートで表示する。
class ServerMonitorDialog extends ConsumerStatefulWidget {
  const ServerMonitorDialog({
    super.key,
    required this.sessionId,
  });

  final String sessionId;

  static Future<void> show(BuildContext context, String sessionId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ServerMonitorDialog(sessionId: sessionId),
    );
  }

  @override
  ConsumerState<ServerMonitorDialog> createState() =>
      _ServerMonitorDialogState();
}

class _ServerMonitorDialogState extends ConsumerState<ServerMonitorDialog> {
  bool _loading = true;
  bool _fetching = false;
  String? _error;
  ServerInfo? _info;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchInfo();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _fetchInfo();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchInfo() async {
    // 前回の fetch がまだ完了していなければスキップ（重複リクエスト防止）
    if (_fetching) return;
    // setState で _fetching = true を反映し、Refresh ボタンを即座に非表示にする。
    // 初回・手動リフレッシュ時（_loading == true）はエラーもクリアする。
    setState(() {
      _fetching = true;
      if (_loading) _error = null;
    });

    try {
      final channelManager = ref
          .read(terminalConnectionProvider(widget.sessionId))
          .channelManager;
      if (channelManager == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'SSH not connected';
        });
        return;
      }

      final info = await _queryServerInfo(channelManager);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _info = info;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    } finally {
      // setState is intentionally omitted here.
      //
      // Dart's event loop guarantees that the `finally` block runs
      // synchronously in the same microtask as the `return` that ends
      // the try/catch — BEFORE the frame that was scheduled by the
      // preceding `setState` call is actually rendered.  When Flutter
      // builds that frame it reads `_fetching` and already sees `false`,
      // so the Refresh button reappears without an extra rebuild.
      //
      // The one exception is the `if (!mounted) return` early-exit paths,
      // where no preceding `setState` was called.  In those cases the
      // widget is unmounted and rebuilding it would be incorrect anyway.
      _fetching = false;
    }
  }

  static const _command = r"""echo '===HOSTNAME===' && hostname && echo '===UNAME===' && uname -sr && echo '===UPTIME===' && (uptime -p 2>/dev/null || uptime) && echo '===LOADAVG===' && cat /proc/loadavg && echo '===MEMORY===' && free -b | head -2 && echo '===DISK===' && (df -B1 --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs 2>/dev/null || df -k) && echo '===PROCS===' && ps aux --sort=-%cpu | head -6 && echo '===END==='""";

  Future<ServerInfo> _queryServerInfo(
      SshChannelManager channelManager) async {
    final output = await channelManager.runCommand(_command).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw Exception('Server monitor timed out (30s)'),
    );
    final text = utf8.decode(output).trim();
    return ServerInfoParser.parse(text);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.8;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  const Icon(Icons.monitor_heart_outlined,
                      color: Colors.white70, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context).serverMonitor,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (!_loading && !_fetching)
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white70),
                      onPressed: () {
                        setState(() => _loading = true);
                        _fetchInfo();
                      },
                      tooltip: AppLocalizations.of(context).refresh,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (_loading && _info == null)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_error != null && _info == null)
                _buildError()
              else if (_info != null)
                Flexible(
                  child: SingleChildScrollView(
                    child: _buildContent(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showKillConfirm(ProcessInfo process) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.killProcess, style: const TextStyle(color: Colors.white)),
        content: Text(
          l.killProcessConfirm(
            process.command.length > 40
                ? '${process.command.substring(0, 40)}…'
                : process.command,
            process.pid,
          ),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel, style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty.all(Colors.redAccent),
            ),
            child: Text(l.kill, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _killProcess(process);
  }

  Future<void> _killProcess(ProcessInfo process) async {
    final l = AppLocalizations.of(context);
    try {
      final channelManager = ref
          .read(terminalConnectionProvider(widget.sessionId))
          .channelManager;
      if (channelManager == null) return;
      await channelManager.runCommand('kill ${process.pid}').timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw Exception('Kill command timed out'),
      );
      if (!mounted) return;
      _fetchInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.processKilled,
              style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.green[700],
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.failedToKillProcess(e.toString()),
              style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.red[700],
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red[900]?.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final info = _info!;
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // System info card
        _buildCard(
          icon: Icons.computer,
          title: l.system,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow(l.host, info.hostname),
              _infoRow(l.os, info.uname),
              _infoRow(l.uptime, info.uptime),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Load average card
        _buildCard(
          icon: Icons.speed,
          title: l.loadAverage,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _loadChip(l.load1Min, info.loadAvg1),
              _loadChip(l.load5Min, info.loadAvg5),
              _loadChip(l.load15Min, info.loadAvg15),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Memory card
        if (info.memTotal > 0) ...[
          _buildCard(
            icon: Icons.memory,
            title: l.memory,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: info.memUsed / info.memTotal,
                    backgroundColor: Colors.white12,
                    color: _usageColor(info.memUsed / info.memTotal),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${humanReadableSize(info.memUsed)} / ${humanReadableSize(info.memTotal)} '
                  '(${(info.memUsed / info.memTotal * 100).toStringAsFixed(1)}%)',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Disk card
        if (info.disks.isNotEmpty) ...[
          _buildCard(
            icon: Icons.storage,
            title: l.disk,
            child: Column(
              children: info.disks
                  .map((d) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Flexible(
                                  child: Text(
                                    d.mountPoint,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${d.usedPercent}%',
                                  style: TextStyle(
                                    color: d.usedPercent >= 90
                                        ? Colors.redAccent
                                        : Colors.white70,
                                    fontSize: 13,
                                    fontWeight: d.usedPercent >= 90
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: d.usedPercent / 100,
                                backgroundColor: Colors.white12,
                                color: _usageColor(d.usedPercent / 100),
                                minHeight: 6,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${humanReadableSize(d.used)} / ${humanReadableSize(d.size)}',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11),
                            ),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Processes card
        if (info.processes.isNotEmpty)
          _buildCard(
            icon: Icons.list_alt,
            title: l.topProcesses,
            child: Column(
              children: [
                // Header row
                Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text('PID',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: Text(l.columnCommand,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(l.columnCpu,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                          textAlign: TextAlign.right),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(l.columnMem,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                          textAlign: TextAlign.right),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                const Divider(color: Colors.white12, height: 8),
                ...info.processes.map((p) {
                  final isCritical = _isCriticalProcess(p);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 36,
                          child: Text(
                            '${p.pid}',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 4,
                          child: Text(
                            p.command,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          width: 56,
                          child: Text(
                            p.cpuPercent,
                            style: const TextStyle(
                                color: Colors.tealAccent, fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        SizedBox(
                          width: 56,
                          child: Text(
                            p.memPercent,
                            style: const TextStyle(
                                color: Colors.lightBlueAccent,
                                fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Icon(
                            isCritical
                                ? Icons.lock
                                : Icons.delete_outline,
                            size: 16,
                            color: isCritical
                                ? Colors.white24
                                : Colors.orangeAccent,
                          ),
                          onPressed: isCritical
                              ? null
                              : () => _showKillConfirm(p),
                          tooltip: isCritical
                              ? ''
                              : l.killProcess,
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints.tightFor(width: 28, height: 28),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCard({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.tealAccent, size: 16),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _loadChip(String label, String value) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    );
  }

  Color _usageColor(double ratio) {
    if (ratio >= 0.9) return Colors.red;
    if (ratio >= 0.7) return Colors.orange;
    if (ratio >= 0.5) return Colors.yellow[700]!;
    return Colors.green;
  }

}

