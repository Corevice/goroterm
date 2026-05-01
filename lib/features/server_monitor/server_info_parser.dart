/// Parsed server info returned by [ServerInfoParser.parse].
class ServerInfo {
  ServerInfo({
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
  final List<DiskInfo> disks;
  final List<ProcessInfo> processes;
}

/// Disk usage information for one mount point.
class DiskInfo {
  DiskInfo({
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

/// CPU / memory usage for a single process.
class ProcessInfo {
  ProcessInfo({
    required this.pid,
    required this.command,
    required this.cpuPercent,
    required this.memPercent,
  });

  final int pid;
  final String command;
  final String cpuPercent;
  final String memPercent;
}

/// Parses the multi-section SSH command output produced by
/// [ServerMonitorDialog._command] into a [ServerInfo] value object.
///
/// Section layout:
/// ```
/// ===HOSTNAME===  … ===UNAME===  … ===UPTIME===  … ===LOADAVG===
/// ===MEMORY===    … ===DISK===   … ===PROCS===   … ===END===
/// ```
class ServerInfoParser {
  ServerInfoParser._();

  static const _sectionOrder = [
    'HOSTNAME',
    'UNAME',
    'UPTIME',
    'LOADAVG',
    'MEMORY',
    'DISK',
    'PROCS',
  ];

  static final _whitespace = RegExp(r'\s+');

  /// Parses [text] (UTF-8 decoded SSH command output) into [ServerInfo].
  static ServerInfo parse(String text) {
    final sections = _splitSections(text);

    final loadParts = _splitLoadAvg(sections['LOADAVG'] ?? '');
    final loadAvg1 = loadParts.isNotEmpty ? loadParts[0] : '0';
    final loadAvg5 = loadParts.length > 1 ? loadParts[1] : '0';
    final loadAvg15 = loadParts.length > 2 ? loadParts[2] : '0';

    final (memTotal, memUsed) = _parseMemory(sections['MEMORY'] ?? '');
    final disks = _parseDisks(sections['DISK'] ?? '');
    final processes = _parseProcesses(sections['PROCS'] ?? '');

    return ServerInfo(
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

  // ---------------------------------------------------------------------------
  // Section splitting
  // ---------------------------------------------------------------------------

  static Map<String, String> _splitSections(String text) {
    // Find all marker positions in one pass (8 searches) instead of the
    // previous O(n²) approach (7 sections × 8 markers = 56 indexOf calls).
    final allTags = [..._sectionOrder, 'END'];
    final markers = <({int pos, int tagLen, String name})>[];
    for (final name in allTags) {
      final tag = '===$name===';
      final pos = text.indexOf(tag);
      if (pos != -1) {
        markers.add((pos: pos, tagLen: tag.length, name: name));
      }
    }
    markers.sort((a, b) => a.pos.compareTo(b.pos));

    final sections = <String, String>{};
    for (var i = 0; i < markers.length; i++) {
      final m = markers[i];
      if (m.name == 'END') continue;
      final contentStart = m.pos + m.tagLen;
      final contentEnd =
          i + 1 < markers.length ? markers[i + 1].pos : text.length;
      sections[m.name] = text.substring(contentStart, contentEnd).trim();
    }
    return sections;
  }

  // ---------------------------------------------------------------------------
  // Per-section parsers
  // ---------------------------------------------------------------------------

  /// Guard against `''.split(...)` returning `['']` instead of `[]`.
  static List<String> _splitLoadAvg(String raw) {
    if (raw.isEmpty) return [];
    return raw.split(_whitespace);
  }

  /// Returns `(total, used)` bytes from `free -b` output.
  static (int, int) _parseMemory(String raw) {
    final lines = raw.split('\n');
    if (lines.length >= 2) {
      final parts = lines[1].trim().split(_whitespace);
      // Mem: total used free shared buff/cache available
      if (parts.length >= 3 && parts[0] == 'Mem:') {
        return (int.tryParse(parts[1]) ?? 0, int.tryParse(parts[2]) ?? 0);
      }
    }
    return (0, 0);
  }

  /// Parses disk lines from either `df -B1 --output=…` (Linux) or `df -k`
  /// (macOS / BSD / fallback Linux).
  ///
  /// `df -B1` header starts with "Mounted on"; sizes are in bytes and the
  /// mount point is column 0.
  ///
  /// `df -k` header starts with "Filesystem"; sizes are in 1 K-blocks and the
  /// mount point is the last column.
  static List<DiskInfo> _parseDisks(String raw) {
    final lines = raw.split('\n');
    final disks = <DiskInfo>[];
    if (lines.isEmpty) return disks;

    final isDfKFormat =
        lines[0].trim().toLowerCase().startsWith('filesystem');

    // Derive the mount-point column start index from the header.
    // The header always ends with "Mounted on" (two tokens), so the number of
    // fixed data columns before the mount point equals headerTokens - 2.
    // Linux df -k:  "Filesystem 1K-blocks Used Available Use% Mounted on"
    //               → 7 tokens → mount starts at index 5
    // macOS df -k:  "Filesystem 1024-blocks Used Available Capacity iused
    //                ifree %iused Mounted on"
    //               → 10 tokens → mount starts at index 8
    // Minimal df -k: "Filesystem 1K-blocks Used Use% Mounted on"
    //               → 6 tokens → mount starts at index 4
    // Defaults to 5 (standard Linux) when the header is absent.
    //
    // Derive the disk-usage percent column from the header token "Use%" or
    // "Capacity". This is robust to non-standard column counts (e.g. a 6-column
    // format without the Available column where Use% shifts to index 3).
    // Falls back to 4 — the position in standard 7-column and 10-column output.
    int dfKMountIndex = 5;
    int dfKPercentIndex = 4;
    if (isDfKFormat) {
      final headerParts = lines[0].trim().split(_whitespace);
      // Require at least "Filesystem ... Mounted on" (4 tokens minimum).
      if (headerParts.length >= 4) {
        dfKMountIndex = headerParts.length - 2;
        final pctIdx = headerParts.indexWhere(
            (t) => t == 'Use%' || t == 'Capacity');
        if (pctIdx >= 0) dfKPercentIndex = pctIdx;
      }
    }

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(_whitespace);

      if (isDfKFormat) {
        // df -k: Filesystem 1K-blocks Used Available [extra…] Use% Mounted-on
        // Mount points may contain spaces (e.g. /Volumes/My Drive), so join
        // everything from dfKMountIndex onward rather than taking parts.last.
        if (parts.length > dfKMountIndex) {
          final mountPoint = parts.sublist(dfKMountIndex).join(' ');
          final sizeKb = int.tryParse(parts[1]) ?? 0;
          final usedKb = int.tryParse(parts[2]) ?? 0;
          final percent =
              int.tryParse(parts[dfKPercentIndex].replaceAll('%', '')) ?? 0;
          final size = sizeKb * 1024;
          final used = usedKb * 1024;
          if (size > 0) {
            disks.add(DiskInfo(
              mountPoint: mountPoint,
              size: size,
              used: used,
              usedPercent: percent,
            ));
          }
        }
      } else {
        // df -B1 --output=target,size,used,avail,pcent
        // Column order: target, size, used, avail, pcent.
        // Mount points may contain spaces (e.g. "/home/my drive"), so derive
        // size/used/percent by counting from the right (always numeric) and
        // reconstruct the mount point by joining everything to the left.
        // This mirrors the df -k mount-point handling above.
        if (parts.length >= 5) {
          final percent = int.tryParse(parts.last.replaceAll('%', '')) ?? 0;
          final used = int.tryParse(parts[parts.length - 3]) ?? 0;
          final size = int.tryParse(parts[parts.length - 4]) ?? 0;
          final mountPoint = parts.sublist(0, parts.length - 4).join(' ');
          if (size > 0) {
            disks.add(DiskInfo(
              mountPoint: mountPoint,
              size: size,
              used: used,
              usedPercent: percent,
            ));
          }
        }
      }
    }
    return disks;
  }

  /// Parses `ps aux` output.  Header row (i == 0) is skipped.
  ///
  /// Column layout:
  /// `USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND…`
  static List<ProcessInfo> _parseProcesses(String raw) {
    final lines = raw.split('\n');
    final processes = <ProcessInfo>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(_whitespace);
      if (parts.length >= 11) {
        final pid = int.tryParse(parts[1]) ?? 0;
        if (pid > 0) {
          processes.add(ProcessInfo(
            pid: pid,
            command: parts.sublist(10).join(' '),
            cpuPercent: parts[2],
            memPercent: parts[3],
          ));
        }
      }
    }
    return processes;
  }
}
