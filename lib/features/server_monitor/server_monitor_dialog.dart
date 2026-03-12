import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ssh/ssh_channel_manager.dart';
import '../terminal/terminal_connection_provider.dart';

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
  String? _error;
  _ServerInfo? _info;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchInfo();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _fetchInfo();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchInfo() async {
    // 初回・手動リフレッシュ時（_loading == true）はエラーをクリアする。
    // Timer.periodic による自動更新時は _loading == false のため、
    // ローディングスピナーを再表示せず既存の表示を維持する。
    if (_loading) setState(() => _error = null);

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
    }
  }

  static const _command = r"""echo '===HOSTNAME===' && hostname && echo '===UNAME===' && uname -sr && echo '===UPTIME===' && (uptime -p 2>/dev/null || uptime) && echo '===LOADAVG===' && cat /proc/loadavg && echo '===MEMORY===' && free -b | head -2 && echo '===DISK===' && (df -B1 --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs 2>/dev/null || df -k) && echo '===PROCS===' && ps aux --sort=-%cpu | head -6 && echo '===END==='""";

  Future<_ServerInfo> _queryServerInfo(
      SshChannelManager channelManager) async {
    final output = await channelManager.runCommand(_command);
    final text = utf8.decode(output).trim();
    return _ServerInfo.parse(text);
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
                  const Expanded(
                    child: Text(
                      'Server Monitor',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (!_loading)
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white70),
                      onPressed: () {
                        setState(() => _loading = true);
                        _fetchInfo();
                      },
                      tooltip: 'Refresh',
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // System info card
        _buildCard(
          icon: Icons.computer,
          title: 'System',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow('Host', info.hostname),
              _infoRow('OS', info.uname),
              _infoRow('Uptime', info.uptime),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Load average card
        _buildCard(
          icon: Icons.speed,
          title: 'Load Average',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _loadChip('1 min', info.loadAvg1),
              _loadChip('5 min', info.loadAvg5),
              _loadChip('15 min', info.loadAvg15),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Memory card
        if (info.memTotal > 0)
          _buildCard(
            icon: Icons.memory,
            title: 'Memory',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: info.memTotal > 0
                        ? info.memUsed / info.memTotal
                        : 0,
                    backgroundColor: Colors.white12,
                    color: _memColor(info.memUsed / info.memTotal),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_formatBytes(info.memUsed)} / ${_formatBytes(info.memTotal)} '
                  '(${(info.memUsed / info.memTotal * 100).toStringAsFixed(1)}%)',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        if (info.memTotal > 0) const SizedBox(height: 12),

        // Disk card
        if (info.disks.isNotEmpty)
          _buildCard(
            icon: Icons.storage,
            title: 'Disk',
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
                                color: _diskColor(d.usedPercent),
                                minHeight: 6,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_formatBytes(d.used)} / ${_formatBytes(d.size)}',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11),
                            ),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
        if (info.disks.isNotEmpty) const SizedBox(height: 12),

        // Processes card
        if (info.processes.isNotEmpty)
          _buildCard(
            icon: Icons.list_alt,
            title: 'Top Processes',
            child: Column(
              children: [
                // Header row
                const Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text('COMMAND',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text('CPU%',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 11),
                          textAlign: TextAlign.right),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text('MEM%',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 11),
                          textAlign: TextAlign.right),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 8),
                ...info.processes.map((p) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
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
                        ],
                      ),
                    )),
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

  Color _memColor(double ratio) {
    if (ratio >= 0.9) return Colors.red;
    if (ratio >= 0.7) return Colors.orange;
    if (ratio >= 0.5) return Colors.yellow[700]!;
    return Colors.green;
  }

  Color _diskColor(int percent) {
    if (percent >= 90) return Colors.red;
    if (percent >= 70) return Colors.orange;
    if (percent >= 50) return Colors.yellow[700]!;
    return Colors.green;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

class _ServerInfo {
  _ServerInfo({
    required this.hostname,
    required this.uname,
    required this.uptime,
    required this.loadAvg1,
    required this.loadAvg5,
    required this.loadAvg15,
    required this.memTotal,
    required this.memUsed,
    required this.disks,
    required this.processes,
  });

  final String hostname;
  final String uname;
  final String uptime;
  final String loadAvg1;
  final String loadAvg5;
  final String loadAvg15;
  final int memTotal;
  final int memUsed;
  final List<_DiskInfo> disks;
  final List<_ProcessInfo> processes;

  factory _ServerInfo.parse(String text) {
    final sections = <String, String>{};
    final sectionOrder = [
      'HOSTNAME',
      'UNAME',
      'UPTIME',
      'LOADAVG',
      'MEMORY',
      'DISK',
      'PROCS',
    ];

    for (final name in sectionOrder) {
      final startTag = '===$name===';
      final startIdx = text.indexOf(startTag);
      if (startIdx == -1) continue;

      final contentStart = startIdx + startTag.length;
      // Find the next section marker or END
      var endIdx = text.length;
      for (final nextName in [...sectionOrder, 'END']) {
        final nextTag = '===$nextName===';
        final nextIdx = text.indexOf(nextTag, contentStart);
        if (nextIdx != -1 && nextIdx < endIdx) {
          endIdx = nextIdx;
        }
      }
      sections[name] = text.substring(contentStart, endIdx).trim();
    }

    // Parse load average
    final loadParts =
        (sections['LOADAVG'] ?? '0 0 0').split(RegExp(r'\s+'));
    final loadAvg1 = loadParts.isNotEmpty ? loadParts[0] : '0';
    final loadAvg5 = loadParts.length > 1 ? loadParts[1] : '0';
    final loadAvg15 = loadParts.length > 2 ? loadParts[2] : '0';

    // Parse memory (free -b output)
    int memTotal = 0;
    int memUsed = 0;
    final memLines = (sections['MEMORY'] ?? '').split('\n');
    if (memLines.length >= 2) {
      final parts = memLines[1].split(RegExp(r'\s+'));
      // Mem: total used free shared buff/cache available
      if (parts.length >= 3) {
        memTotal = int.tryParse(parts[1]) ?? 0;
        memUsed = int.tryParse(parts[2]) ?? 0;
      }
    }

    // Parse disk
    // Two possible formats:
    //   df -B1 --output=target,size,used,avail,pcent (Linux):
    //     header starts with "Mounted on", sizes in bytes, mount is col 0
    //   df -k fallback (macOS/BSD/Linux):
    //     header starts with "Filesystem", sizes in 1K-blocks, mount is last col
    final diskLines = (sections['DISK'] ?? '').split('\n');
    final disks = <_DiskInfo>[];
    final isDfKFormat = diskLines.isNotEmpty &&
        diskLines[0].trim().toLowerCase().startsWith('filesystem');
    for (var i = 0; i < diskLines.length; i++) {
      final line = diskLines[i].trim();
      if (line.isEmpty || i == 0) continue; // skip header
      final parts = line.split(RegExp(r'\s+'));
      if (isDfKFormat) {
        // df -k: Filesystem 1K-blocks Used Available Use% [iused ifree %iused] Mounted-on
        if (parts.length >= 6) {
          final mountPoint = parts.last;
          final sizeKb = int.tryParse(parts[1]) ?? 0;
          final usedKb = int.tryParse(parts[2]) ?? 0;
          final percentStr = parts[4].replaceAll('%', '');
          final percent = int.tryParse(percentStr) ?? 0;
          final size = sizeKb * 1024;
          final used = usedKb * 1024;
          if (size > 0) {
            disks.add(_DiskInfo(
              mountPoint: mountPoint,
              size: size,
              used: used,
              usedPercent: percent,
            ));
          }
        }
      } else {
        // df -B1 --output=target,size,used,avail,pcent: mount is col 0, sizes in bytes
        if (parts.length >= 5) {
          final mountPoint = parts[0];
          final size = int.tryParse(parts[1]) ?? 0;
          final used = int.tryParse(parts[2]) ?? 0;
          final percentStr = parts[4].replaceAll('%', '');
          final percent = int.tryParse(percentStr) ?? 0;
          if (size > 0) {
            disks.add(_DiskInfo(
              mountPoint: mountPoint,
              size: size,
              used: used,
              usedPercent: percent,
            ));
          }
        }
      }
    }

    // Parse processes
    final procLines = (sections['PROCS'] ?? '').split('\n');
    final processes = <_ProcessInfo>[];
    for (var i = 0; i < procLines.length; i++) {
      final line = procLines[i].trim();
      if (line.isEmpty || i == 0) continue; // skip header
      final parts = line.split(RegExp(r'\s+'));
      // USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND...
      if (parts.length >= 11) {
        final cpuPercent = parts[2];
        final memPercent = parts[3];
        final command = parts.sublist(10).join(' ');
        processes.add(_ProcessInfo(
          command: command,
          cpuPercent: cpuPercent,
          memPercent: memPercent,
        ));
      }
    }

    return _ServerInfo(
      hostname: sections['HOSTNAME'] ?? 'unknown',
      uname: sections['UNAME'] ?? 'unknown',
      uptime: sections['UPTIME'] ?? 'unknown',
      loadAvg1: loadAvg1,
      loadAvg5: loadAvg5,
      loadAvg15: loadAvg15,
      memTotal: memTotal,
      memUsed: memUsed,
      disks: disks,
      processes: processes,
    );
  }
}

class _DiskInfo {
  _DiskInfo({
    required this.mountPoint,
    required this.size,
    required this.used,
    required this.usedPercent,
  });

  final String mountPoint;
  final int size;
  final int used;
  final int usedPercent;
}

class _ProcessInfo {
  _ProcessInfo({
    required this.command,
    required this.cpuPercent,
    required this.memPercent,
  });

  final String command;
  final String cpuPercent;
  final String memPercent;
}
