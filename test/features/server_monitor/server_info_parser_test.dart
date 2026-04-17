import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/features/server_monitor/server_info_parser.dart';

void main() {
  group('ServerInfoParser.parse', () {
    // -------------------------------------------------------------------------
    // Full happy-path output (df -B1 Linux format)
    // -------------------------------------------------------------------------
    const fullOutput = '''
===HOSTNAME===
prod-server
===UNAME===
Linux 6.1.0-generic
===UPTIME===
up 5 days, 4 hours, 12 minutes
===LOADAVG===
1.25 0.87 0.54 3/512 9876
===MEMORY===
              total        used        free      shared  buff/cache   available
Mem:     8589934592  3221225472  2147483648   134217728  3221225472  5368709120
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  50%
/home           53687091200 10737418240 42949672960  20%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  8.5  2.1 111111 22222 ?        Ss   Jan01   1:00 /sbin/init
www        100  3.2  1.0 222222 33333 ?        S    Jan02   2:00 nginx: worker process
===END===
''';

    test('parses hostname, uname, uptime', () {
      final info = ServerInfoParser.parse(fullOutput);
      expect(info.hostname, 'prod-server');
      expect(info.uname, 'Linux 6.1.0-generic');
      expect(info.uptime, 'up 5 days, 4 hours, 12 minutes');
    });

    test('parses load averages', () {
      final info = ServerInfoParser.parse(fullOutput);
      expect(info.loadAvg1, '1.25');
      expect(info.loadAvg5, '0.87');
      expect(info.loadAvg15, '0.54');
    });

    test('parses memory in bytes', () {
      final info = ServerInfoParser.parse(fullOutput);
      expect(info.memTotal, 8589934592);
      expect(info.memUsed, 3221225472);
    });

    test('parses df -B1 disk entries', () {
      final info = ServerInfoParser.parse(fullOutput);
      expect(info.disks.length, 2);

      final root = info.disks[0];
      expect(root.mountPoint, '/');
      expect(root.size, 107374182400);
      expect(root.used, 53687091200);
      expect(root.usedPercent, 50);

      final home = info.disks[1];
      expect(home.mountPoint, '/home');
      expect(home.usedPercent, 20);
    });

    test('parses ps aux processes', () {
      final info = ServerInfoParser.parse(fullOutput);
      expect(info.processes.length, 2);

      final first = info.processes[0];
      expect(first.command, '/sbin/init');
      expect(first.cpuPercent, '8.5');
      expect(first.memPercent, '2.1');

      final second = info.processes[1];
      expect(second.command, 'nginx: worker process');
    });

    // -------------------------------------------------------------------------
    // df -k format (macOS / BSD / fallback Linux)
    // -------------------------------------------------------------------------
    const dfKOutput = '''
===HOSTNAME===
mac-server
===UNAME===
Darwin 23.0.0
===UPTIME===
up 1 day
===LOADAVG===
0.10 0.20 0.30 1/100 1234
===MEMORY===

===DISK===
Filesystem      1K-blocks      Used Available Use% Mounted on
/dev/disk1s1    976762584 500000000 476762584  52% /
/dev/disk1s4     976762584  10000000 966762584   2% /Volumes/Data
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.1  0.5  10000  5000 ?        Ss   10:00   0:01 launchd
===END===
''';

    test('parses df -k format disk entries', () {
      final info = ServerInfoParser.parse(dfKOutput);
      expect(info.disks.length, 2);

      final root = info.disks[0];
      expect(root.mountPoint, '/');
      expect(root.size, 976762584 * 1024);
      expect(root.used, 500000000 * 1024);
      expect(root.usedPercent, 52);

      final data = info.disks[1];
      expect(data.mountPoint, '/Volumes/Data');
      expect(data.usedPercent, 2);
    });

    // -------------------------------------------------------------------------
    // df -k macOS extended format (iused/ifree/%iused columns)
    // -------------------------------------------------------------------------
    // macOS df -k includes inode-usage columns when run without -P:
    //   Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on
    // This produces a 10-token header → dfKMountIndex = 8.
    // Both the column-index derivation and space-containing mount points must
    // work correctly with this wider format.
    test('parses macOS extended df -k format (10-column header, iused/ifree columns)',
        () {
      const output = '''
===DISK===
Filesystem    1024-blocks      Used  Available Capacity   iused      ifree %iused  Mounted on
/dev/disk1s1   975619072  55000000  920619072       6%  567890    9000000    6%  /
/dev/disk2s1   975619072  10000000  965619072       2%  100000   10000000    1%  /Volumes/My Drive
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks.length, 2);

      final root = info.disks[0];
      expect(root.mountPoint, '/');
      expect(root.size, 975619072 * 1024);
      expect(root.used, 55000000 * 1024);
      expect(root.usedPercent, 6);

      final myDrive = info.disks[1];
      expect(myDrive.mountPoint, '/Volumes/My Drive');
      expect(myDrive.size, 975619072 * 1024);
      expect(myDrive.used, 10000000 * 1024);
      expect(myDrive.usedPercent, 2);
    });

    // -------------------------------------------------------------------------
    // Empty / missing sections
    // -------------------------------------------------------------------------
    test('returns defaults when all sections missing', () {
      final info = ServerInfoParser.parse('===HOSTNAME===\nbox\n===END===');
      expect(info.hostname, 'box');
      expect(info.uname, 'unknown');
      expect(info.loadAvg1, '0');
      expect(info.loadAvg5, '0');
      expect(info.loadAvg15, '0');
      expect(info.memTotal, 0);
      expect(info.memUsed, 0);
      expect(info.disks, isEmpty);
      expect(info.processes, isEmpty);
    });

    test('returns "0" for each load field when LOADAVG section is empty', () {
      const output = '===LOADAVG===\n===END===';
      final info = ServerInfoParser.parse(output);
      expect(info.loadAvg1, '0');
      expect(info.loadAvg5, '0');
      expect(info.loadAvg15, '0');
    });

    test('returns zero memory when MEMORY section has only one line', () {
      const output = '===MEMORY===\n              total        used\n===END===';
      final info = ServerInfoParser.parse(output);
      expect(info.memTotal, 0);
      expect(info.memUsed, 0);
    });

    test('parses memory when Mem: line has leading whitespace', () {
      // Some systems emit `free -b` output with a leading space before "Mem:".
      // Without trim(), split(r'\s+') produces an empty first element that
      // shifts all column indices, causing total to parse as 0.
      const output = '''
===MEMORY===
              total        used        free
 Mem:     8589934592  3221225472  5368709120
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.memTotal, 8589934592);
      expect(info.memUsed, 3221225472);
    });

    test('returns zero memory when second line is not Mem:', () {
      // If free -b output is missing the Mem: row (e.g. only Swap: is present),
      // the parser must not silently misread Swap: values as memory figures.
      const output = '''
===MEMORY===
              total        used        free
Swap:    2147483648   536870912  1610612736
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.memTotal, 0);
      expect(info.memUsed, 0);
    });

    test('skips disk entries with zero size', () {
      const output = '''
===DISK===
Mounted on          1B-blocks  Used  Avail Use%
/                           0     0      0   0%
/data          107374182400  1000  1000   1%
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks.length, 1);
      expect(info.disks[0].mountPoint, '/data');
    });

    test('handles completely empty output without throwing', () {
      final info = ServerInfoParser.parse('');
      expect(info.hostname, 'unknown');
      expect(info.disks, isEmpty);
      expect(info.processes, isEmpty);
    });

    test('parses sections that appear out of declared order', () {
      // Sections in reverse order: PROCS before HOSTNAME.
      const output = '''
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY  STAT START  TIME COMMAND
root         1  1.0  0.5 10000  5000 ?    Ss   Jan01  0:01 init
===HOSTNAME===
out-of-order-host
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.hostname, 'out-of-order-host');
      expect(info.processes.length, 1);
      expect(info.processes[0].command, 'init');
    });

    test('extracts last section content when END marker is absent', () {
      // No ===END=== — content of the last section extends to end of string.
      const output = '===HOSTNAME===\nno-end-marker';
      final info = ServerInfoParser.parse(output);
      expect(info.hostname, 'no-end-marker');
    });

    // -------------------------------------------------------------------------
    // df -k: 6-column header (no Available column) — Use% at index 3
    //
    // Some minimal or embedded df implementations omit the Available column:
    //   Filesystem 1K-blocks Used Use% Mounted on  (6 tokens, Use% at index 3)
    // With the old hardcoded parts[4] this would silently read the mount-point
    // token as the percent value (int.tryParse('/') = null → 0).
    // The dynamic header lookup must find "Use%" at index 3 and use that.
    // -------------------------------------------------------------------------
    test('parses 6-column df -k format where Use% is at index 3 (no Available column)',
        () {
      const output = '''
===DISK===
Filesystem 1K-blocks Used Use% Mounted on
/dev/sda1 976762584 500000000 52% /
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks.length, 1);
      expect(info.disks[0].mountPoint, '/');
      expect(info.disks[0].size, 976762584 * 1024);
      expect(info.disks[0].used, 500000000 * 1024);
      expect(info.disks[0].usedPercent, 52,
          reason:
              'Use% must be read from index 3 (not the hardcoded index 4 '
              'which would point at the mount-point token)');
    });

    // -------------------------------------------------------------------------
    // df -k: mount point with spaces
    // -------------------------------------------------------------------------
    test('parses df -k mount point that contains spaces', () {
      // macOS volumes like "/Volumes/My Drive" have a space in the name.
      // Splitting by whitespace produces extra tokens; all tokens from column 5
      // onward must be re-joined to reconstruct the full mount point.
      const output = '''
===DISK===
Filesystem      1K-blocks      Used Available Use% Mounted on
/dev/disk0s1    976762584 500000000 476762584  52% /Volumes/My Drive
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks.length, 1);
      expect(info.disks[0].mountPoint, '/Volumes/My Drive');
      expect(info.disks[0].size, 976762584 * 1024);
      expect(info.disks[0].used, 500000000 * 1024);
      expect(info.disks[0].usedPercent, 52);
    });

    // -------------------------------------------------------------------------
    // Malformed / truncated lines are silently skipped
    // -------------------------------------------------------------------------
    test('skips df -k lines that are too short for dfKMountIndex', () {
      // 7-token header → dfKMountIndex = 5. A data line with only 5 tokens
      // (parts.length == 5, not > 5) must be silently dropped.
      const output = '''
===DISK===
Filesystem      1K-blocks      Used Available Use% Mounted on
/dev/disk0s1    976762584 500000000 476762584  52%
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks, isEmpty);
    });

    test('skips df -B1 lines that have fewer than 5 columns', () {
      // df -B1 path requires parts.length >= 5. A line with only 3 tokens
      // must be silently dropped.
      const output = '''
===DISK===
Mounted on          1B-blocks        Used
/              107374182400 53687091200
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks, isEmpty);
    });

    // -------------------------------------------------------------------------
    // df -B1: mount point with spaces
    //
    // Linux mount points can contain spaces (e.g. "/home/my drive").
    // The parser must derive size/used/percent by counting from the right
    // (always numeric) and reconstruct the mount point from everything left,
    // mirroring the df -k mount-point handling.
    // -------------------------------------------------------------------------
    test('parses df -B1 mount point that contains spaces', () {
      const output = '''
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/home/my drive  107374182400 53687091200 48318382080  50%
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks.length, 1);
      expect(info.disks[0].mountPoint, '/home/my drive');
      expect(info.disks[0].size, 107374182400);
      expect(info.disks[0].used, 53687091200);
      expect(info.disks[0].usedPercent, 50);
    });

    test('parses df -B1 mount point with multiple spaces', () {
      // Mount point with two words after the initial slash.
      const output = '''
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/mnt/data disk  53687091200 10737418240 42949672960  20%
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks.length, 1);
      expect(info.disks[0].mountPoint, '/mnt/data disk');
      expect(info.disks[0].size, 53687091200);
      expect(info.disks[0].used, 10737418240);
      expect(info.disks[0].usedPercent, 20);
    });

    test('skips ps aux lines that have fewer than 11 columns', () {
      // _parseProcesses requires parts.length >= 11. A truncated ps line
      // (only 5 tokens) must be silently dropped.
      const output = '''
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY  STAT START  TIME COMMAND
root         1  1.0  0.5
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.processes, isEmpty);
    });

    // -------------------------------------------------------------------------
    // int.tryParse fallback: non-numeric values in numeric fields
    // -------------------------------------------------------------------------

    test('returns zero for memTotal when Mem: total value is non-numeric', () {
      // If `free -b` outputs a non-numeric token (e.g. 'N/A') for the total
      // column, int.tryParse returns null and the ?? 0 fallback must apply.
      // The used field is still parsed normally.
      const output = '''
===MEMORY===
              total        used        free
Mem:     N/A  3221225472  5368709120
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.memTotal, 0);
      expect(info.memUsed, 3221225472);
    });

    test('returns zero for memUsed when Mem: used value is non-numeric', () {
      // Same ?? 0 fallback for the used column.
      const output = '''
===MEMORY===
              total        used        free
Mem:     8589934592  N/A  5368709120
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.memTotal, 8589934592);
      expect(info.memUsed, 0);
    });

    test('disk entry has zero used when df -B1 used value is non-numeric', () {
      // int.tryParse on a non-numeric "used" token falls back to 0.
      // The entry is still included because size > 0.
      const output = '''
===DISK===
Mounted on          1B-blocks  Used  Avail Use%
/              107374182400   N/A  50000000  50%
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks.length, 1);
      expect(info.disks[0].used, 0);
      expect(info.disks[0].size, 107374182400);
      expect(info.disks[0].usedPercent, 50);
    });

    test('disk entry has zero usedPercent when df -B1 percent value is non-numeric', () {
      // int.tryParse on a non-numeric percent token (after % removal) falls back to 0.
      const output = '''
===DISK===
Mounted on          1B-blocks  Used  Avail Use%
/              107374182400  53000000  54000000  N/A
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.disks.length, 1);
      expect(info.disks[0].usedPercent, 0);
      expect(info.disks[0].size, 107374182400);
    });

    // -------------------------------------------------------------------------
    // Process command with spaces (sublist join)
    // -------------------------------------------------------------------------
    test('joins multi-word command with spaces', () {
      const output = '''
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY  STAT START  TIME COMMAND
root         1  1.0  0.5 10000  5000 ?    Ss   Jan01  0:01 /usr/bin/python3 manage.py runserver
===END===
''';
      final info = ServerInfoParser.parse(output);
      expect(info.processes.length, 1);
      expect(
          info.processes[0].command, '/usr/bin/python3 manage.py runserver');
    });
  });
}
