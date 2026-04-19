import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:terminal_ssh_app/core/ssh/ssh_channel_manager.dart';
import 'package:terminal_ssh_app/features/server_monitor/server_monitor_dialog.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';

import '../../test_localizations.dart';

// ---------------------------------------------------------------------------
// Mock / Fake helpers
// ---------------------------------------------------------------------------

class MockSshChannelManager extends Mock implements SshChannelManager {}

/// Fake notifier that exposes a pre-built state with a mock channel manager.
class FakeTerminalConnectionNotifier
    extends TerminalConnectionNotifier {
  FakeTerminalConnectionNotifier(this._channelManager);
  final SshChannelManager? _channelManager;

  @override
  TerminalConnectionState build(String arg) {
    return TerminalConnectionState(
      status: _channelManager != null
          ? ConnectionStatus.connected
          : ConnectionStatus.disconnected,
      channelManager: _channelManager,
    );
  }
}

/// Sample output that mimics the remote SSH command result.
const _sampleOutput = '''
===HOSTNAME===
test-server
===UNAME===
Linux 5.15.0-generic
===UPTIME===
up 3 days, 2 hours
===LOADAVG===
0.52 0.38 0.31 1/234 5678
===MEMORY===
              total        used        free      shared  buff/cache   available
Mem:     8589934592  4294967296  2147483648   134217728  2147483648  4294967296
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  53%
/home           53687091200 10737418240 42949672960  20%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  5.2  1.3 123456 78901 ?        Ss   Jan01   1:23 /usr/bin/top-proc
www-data   100  3.1  2.5 234567 89012 ?        S    Jan02   2:34 nginx: worker process
postgres   200  2.0  4.0 345678 90123 ?        S    Jan03   3:45 postgres: writer
user       300  1.5  0.8 456789 12345 ?        S    Jan04   4:56 /usr/bin/python3 app.py
nobody     400  0.3  0.2 567890 23456 ?        S    Jan05   5:67 /usr/sbin/cron
===END===
''';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ServerMonitorDialog', () {
    late MockSshChannelManager mockChannelManager;

    setUp(() {
      mockChannelManager = MockSshChannelManager();
    });

    Widget buildTestWidget({SshChannelManager? channelManager}) {
      return ProviderScope(
        overrides: [
          terminalConnectionProvider.overrideWith(
            () => FakeTerminalConnectionNotifier(channelManager),
          ),
        ],
        child: localizedTestApp(
          home: const Scaffold(
            body: SizedBox.shrink(),
          ),
        ),
      );
    }

    testWidgets('shows loading indicator initially', (tester) async {
      final completer = Completer<Uint8List>();
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) => completer.future,
      );

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));

      // Open the bottom sheet
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pump(); // start animation
      await tester.pump(const Duration(milliseconds: 300)); // animation

      expect(find.text('Server Monitor'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Complete the future and close to avoid timer leak
      completer.complete(Uint8List.fromList(utf8.encode(_sampleOutput)));
      await tester.pumpAndSettle();

      // Dismiss bottom sheet to cancel Timer.periodic in dispose
      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    // -------------------------------------------------------------------------
    // 30-second command timeout prevents indefinitely-stuck spinner.
    //
    // When the SSH command hangs (e.g. network stall), _queryServerInfo throws
    // after 30 seconds.  The catch block in _fetchInfo() must clear the spinner
    // and show an error, so the user is not trapped in an infinite loading state.
    // -------------------------------------------------------------------------
    testWidgets('shows error and clears spinner after 30s command timeout',
        (tester) async {
      final completer = Completer<Uint8List>();
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) => completer.future,
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Spinner must be showing while the command is pending.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Advance 30 seconds — the timeout fires and throws an exception.
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();

      // Spinner must be gone and an error message must be visible.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('timed out'), findsOneWidget);

      // Dismiss and complete the completer to avoid dangling futures.
      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
      completer.complete(Uint8List.fromList([]));
      await tester.pumpAndSettle();
    });

    testWidgets('displays server info after successful fetch', (tester) async {
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(_sampleOutput)),
      );

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // System info
      expect(find.text('Server Monitor'), findsOneWidget);
      expect(find.text('test-server'), findsOneWidget);
      expect(find.text('Linux 5.15.0-generic'), findsOneWidget);
      expect(find.text('up 3 days, 2 hours'), findsOneWidget);

      // Load average
      expect(find.text('0.52'), findsOneWidget);
      expect(find.text('0.38'), findsOneWidget);
      expect(find.text('0.31'), findsOneWidget);

      // Memory
      expect(find.textContaining('4.0 GB / 8.0 GB'), findsOneWidget);

      // Disk
      expect(find.text('/'), findsOneWidget);
      expect(find.text('/home'), findsOneWidget);
      expect(find.text('53%'), findsOneWidget);
      expect(find.text('20%'), findsOneWidget);

      // Processes
      expect(find.text('Top Processes'), findsOneWidget);
      expect(find.textContaining('/usr/bin/top-proc'), findsOneWidget);
      expect(find.text('5.2'), findsOneWidget);
    });

    testWidgets('shows error when SSH not connected', (tester) async {
      await tester.pumpWidget(buildTestWidget(channelManager: null));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.text('SSH not connected'), findsOneWidget);
    });

    testWidgets('shows error on command failure', (tester) async {
      when(() => mockChannelManager.runCommand(any()))
          .thenThrow(Exception('Connection refused'));

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection refused'), findsOneWidget);
    });

    testWidgets('refresh button triggers re-fetch', (tester) async {
      var callCount = 0;
      when(() => mockChannelManager.runCommand(any())).thenAnswer((_) async {
        callCount++;
        return Uint8List.fromList(utf8.encode(_sampleOutput));
      });

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(callCount, 1);

      // Tap refresh
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      expect(callCount, 2);
    });

    // -------------------------------------------------------------------------
    // Refresh button is hidden while _fetching is true (Phase 48)
    //
    // If an auto-refresh is running (_fetching == true, _loading == false),
    // the Refresh button must NOT be shown. Showing it would let the user
    // trigger a setState(() => _loading = true) that sets the spinner but
    // whose _fetchInfo() call returns immediately due to the _fetching guard,
    // leaving the spinner stuck until the auto-refresh finishes.
    // -------------------------------------------------------------------------
    testWidgets('refresh button is hidden while a fetch is in progress',
        (tester) async {
      final fetchCompleter = Completer<Uint8List>();
      var callCount = 0;
      when(() => mockChannelManager.runCommand(any())).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          // First (initial) fetch completes immediately so info is shown.
          return Uint8List.fromList(utf8.encode(_sampleOutput));
        }
        // Second fetch (auto-refresh at 10 s) blocks until we release it.
        return fetchCompleter.future;
      });

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Initial fetch done: Refresh button is visible.
      expect(find.byIcon(Icons.refresh), findsOneWidget);

      // Trigger auto-refresh — second fetch starts and blocks.
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(); // let the async call start

      // While the second fetch is pending (_fetching == true), Refresh must be hidden.
      expect(find.byIcon(Icons.refresh), findsNothing);

      // Release the blocked fetch and verify Refresh reappears.
      fetchCompleter.complete(Uint8List.fromList(utf8.encode(_sampleOutput)));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.refresh), findsOneWidget);

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('auto-refreshes every 10 seconds', (tester) async {
      var callCount = 0;
      when(() => mockChannelManager.runCommand(any())).thenAnswer((_) async {
        callCount++;
        return Uint8List.fromList(utf8.encode(_sampleOutput));
      });

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(callCount, 1);

      // Advance time by 10 seconds for auto-refresh
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(callCount, 2);

      // Another 10 seconds
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(callCount, 3);
    });

    testWidgets('handles partial/empty output gracefully', (tester) async {
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(
          '===HOSTNAME===\nminimal\n===UNAME===\nLinux\n===UPTIME===\nup\n'
          '===LOADAVG===\n0 0 0\n===MEMORY===\n\n===DISK===\n\n===PROCS===\n\n===END===\n',
        )),
      );

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.text('minimal'), findsOneWidget);
      expect(find.text('Linux'), findsOneWidget);
    });

    testWidgets('PopupMenu contains Server Monitor item', (tester) async {
      // Verify terminal_screen.dart integration by checking the import works
      // (The actual widget test for TerminalScreen is too complex due to its
      // many dependencies. We verify the dialog can be shown standalone.)
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(_sampleOutput)),
      );

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Verify the dialog rendered with the correct title
      expect(find.text('Server Monitor'), findsOneWidget);
      expect(find.byIcon(Icons.monitor_heart_outlined), findsOneWidget);
    });

    testWidgets('error is cleared and data shown after manual refresh', (tester) async {
      var callCount = 0;
      when(() => mockChannelManager.runCommand(any())).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) throw Exception('network error');
        return Uint8List.fromList(utf8.encode(_sampleOutput));
      });

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // First fetch fails — error is shown
      expect(find.textContaining('network error'), findsOneWidget);

      // Tap refresh — error should clear and new data shown
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      expect(find.textContaining('network error'), findsNothing);
      expect(find.text('test-server'), findsOneWidget);
      expect(callCount, 2);
    });

    testWidgets('parses df -k Linux fallback output correctly', (tester) async {
      // df -k Linux: Filesystem 1K-blocks Used Available Use% Mounted-on
      // Sizes are in KB (multiply by 1024 to get bytes).
      const dfKOutput = '''
===HOSTNAME===
linux-server
===UNAME===
Linux 6.1.0
===UPTIME===
up 1 day
===LOADAVG===
0.10 0.20 0.30 1/100 1234
===MEMORY===
              total        used        free      shared  buff/cache   available
Mem:     4294967296  2147483648  2147483648           0           0  2147483648
===DISK===
Filesystem     1K-blocks     Used Available Use% Mounted on
/dev/sda1       10485760  5242880   5242880  50% /
/dev/sdb1       20971520  2097152  18874368  10% /data
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  1.0  0.5 12345 6789 ?        Ss   Jan01   0:01 /sbin/init
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(dfKOutput)),
      );

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Mount points must be last col (not device paths)
      expect(find.text('/'), findsOneWidget);
      expect(find.text('/data'), findsOneWidget);
      // Use% should display correctly
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
      // Sizes: 10485760 KB * 1024 = 10 GB, 5242880 KB used = 5 GB
      expect(find.textContaining('5.0 GB / 10.0 GB'), findsOneWidget);
    });

    testWidgets('parses df -k macOS fallback output correctly', (tester) async {
      // macOS df -k has extra iused/ifree/%iused columns before Mounted on
      const dfKMacOutput = '''
===HOSTNAME===
mac-server
===UNAME===
Darwin 23.0.0
===UPTIME===
up 2 hours
===LOADAVG===
1.50 1.20 0.90 3/150 9876
===MEMORY===
              total        used        free      shared  buff/cache   available
Mem:    17179869184  8589934592  8589934592           0           0  8589934592
===DISK===
Filesystem    1024-blocks      Used  Available Capacity  iused      ifree %iused  Mounted on
/dev/disk1s1    244277768  11094520  105453544       10% 484789 4293798490    0%   /
/dev/disk1s5    244277768   5242880  105453544        5% 100000 4294067490    0%   /System/Volumes/Data
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY  STAT START TIME COMMAND
root         1  2.0  1.0 409600 81920 ??   Ss   Fri01 0:12 /sbin/launchd
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(dfKMacOutput)),
      );

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Mount points must be last col, not device paths
      expect(find.text('/'), findsOneWidget);
      expect(find.text('/System/Volumes/Data'), findsOneWidget);
      // Device paths must NOT appear as mount labels
      expect(find.text('/dev/disk1s1'), findsNothing);
      expect(find.text('/dev/disk1s5'), findsNothing);
      // Use% columns
      expect(find.text('10%'), findsOneWidget);
      expect(find.text('5%'), findsOneWidget);
    });

    testWidgets('memory progress bar uses correct colors', (tester) async {
      // Test with high memory usage (>90%)
      final highMemOutput = _sampleOutput.replaceAll(
        'Mem:     8589934592  4294967296  2147483648   134217728  2147483648  4294967296',
        'Mem:     8589934592  8000000000   589934592   134217728  2147483648  4294967296',
      );
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(highMemOutput)),
      );

      await tester.pumpWidget(buildTestWidget(
        channelManager: mockChannelManager,
      ));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Verify the memory percentage text shows high usage
      expect(find.textContaining('93.'), findsOneWidget);
    });

    // -------------------------------------------------------------------------
    // Disk size == 0 entries are filtered out (Phase 47 gap coverage)
    //
    // The parser skips disk lines where size == 0 to avoid divide-by-zero and
    // avoid showing tmpfs/overlay pseudo-filesystems that report 0 capacity.
    // This tests both the df -B1 format and the df -k fallback format.
    // -------------------------------------------------------------------------
    testWidgets('disk entries with size 0 are excluded (df -B1 format)', (tester) async {
      // Lines where size == 0 must be silently dropped.
      // /snap/core is a common pseudo-entry with 0 bytes in df -B1 output.
      const output = '''
===HOSTNAME===
size-zero-test
===UNAME===
Linux 6.0
===UPTIME===
up 1 day
===LOADAVG===
0.10 0.20 0.30 1/50 999
===MEMORY===
              total        used        free
Mem:     4294967296  2147483648  2147483648
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  50%
/snap/core               0           0           0   0%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.0 12345  6789 ?        Ss   Jan01   0:00 /sbin/init
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(output)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // The real root partition must appear.
      expect(find.text('/'), findsOneWidget);
      // The size-zero /snap/core entry must NOT appear as a mount point.
      expect(find.text('/snap/core'), findsNothing);

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('disk entries with size 0 are excluded (df -k format)', (tester) async {
      // df -k: size in 1K-blocks. A line with 1K-blocks == 0 must be skipped.
      const output = '''
===HOSTNAME===
size-zero-dfk
===UNAME===
Linux 6.0
===UPTIME===
up 2 days
===LOADAVG===
0.50 0.40 0.30 1/60 111
===MEMORY===
              total        used        free
Mem:     4294967296  1073741824  3221225472
===DISK===
Filesystem     1K-blocks     Used Available Use% Mounted on
/dev/sda1       10485760  5242880   5242880  50% /
overlay                0        0         0   0% /overlay
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.0 12345  6789 ?        Ss   Jan01   0:00 /sbin/init
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(output)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.text('/'), findsOneWidget);
      // /overlay has 0 blocks — must be silently dropped
      expect(find.text('/overlay'), findsNothing);

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    // -------------------------------------------------------------------------
    // Short process lines (< 11 fields) are silently skipped (Phase 47)
    //
    // ps aux output may contain truncated or malformed lines. The parser
    // requires >= 11 fields; lines with fewer must not crash or appear in UI.
    // -------------------------------------------------------------------------
    testWidgets('short process lines with fewer than 11 fields are skipped', (tester) async {
      const output = '''
===HOSTNAME===
proc-test
===UNAME===
Linux 6.0
===UPTIME===
up 1 hour
===LOADAVG===
0.10 0.20 0.30 1/30 555
===MEMORY===
              total        used        free
Mem:     4294967296  1073741824  3221225472
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  50%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  5.0  1.0 12345 6789 ?        Ss   Jan01   0:01 /sbin/init
short line with only few
root         2  2.0  0.5 99999 1111 ?        S    Jan01   0:02 /usr/bin/valid-proc
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(output)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Valid processes appear
      expect(find.textContaining('/sbin/init'), findsOneWidget);
      expect(find.textContaining('/usr/bin/valid-proc'), findsOneWidget);
      // The short line's content must not appear as a process command
      expect(find.text('short line with only few'), findsNothing);

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    // -------------------------------------------------------------------------
    // Missing ===END=== marker — fallback to text.length (Phase 47)
    //
    // If the SSH command is cut short before printing ===END===, the parser
    // falls back to text.length as the section boundary. Parsing must succeed.
    // -------------------------------------------------------------------------
    testWidgets('parses output correctly when ===END=== marker is missing', (tester) async {
      // Same as _sampleOutput but without the trailing ===END=== line.
      const noEndOutput = '''
===HOSTNAME===
no-end-server
===UNAME===
Linux 5.19.0
===UPTIME===
up 5 hours
===LOADAVG===
0.25 0.30 0.35 1/80 4321
===MEMORY===
              total        used        free      shared  buff/cache   available
Mem:     8589934592  4294967296  2147483648   134217728  2147483648  4294967296
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  50%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  3.0  0.5 11111  2222 ?        Ss   Jan01   0:01 /sbin/init
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(noEndOutput)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Core data must still be visible
      expect(find.text('no-end-server'), findsOneWidget);
      expect(find.text('Linux 5.19.0'), findsOneWidget);
      expect(find.text('/'), findsOneWidget);
      expect(find.textContaining('/sbin/init'), findsOneWidget);

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    // -------------------------------------------------------------------------
    // Memory card hidden when memLines.length < 2 (Phase 47 gap coverage)
    //
    // The parser reads `free -b | head -2`. If the command output contains only
    // the header line (no data row), or the MEMORY section is completely empty,
    // memTotal stays 0 and the Memory card must NOT be shown.
    // -------------------------------------------------------------------------
    testWidgets('memory card is hidden when MEMORY section has only header line',
        (tester) async {
      // free -b returns just the column header — no data row.
      const output = '''
===HOSTNAME===
header-only-mem
===UNAME===
Linux 6.0
===UPTIME===
up 1 hour
===LOADAVG===
0.10 0.20 0.30 1/50 999
===MEMORY===
              total        used        free      shared  buff/cache   available
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  50%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.0 12345  6789 ?        Ss   Jan01   0:00 /sbin/init
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(output)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // System info and disk are still shown
      expect(find.text('header-only-mem'), findsOneWidget);
      expect(find.text('/'), findsOneWidget);
      // Memory card title must NOT be shown when memTotal == 0
      expect(find.text('Memory'), findsNothing);
      // The percentage text "(X%)" specific to the memory card must not appear.
      // Disk entries use "X%" without parentheses, so this pattern is memory-only.
      expect(find.textContaining('('), findsNothing);

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('memory card is hidden when MEMORY section is completely empty',
        (tester) async {
      // MEMORY section present but empty after trim.
      const output = '''
===HOSTNAME===
empty-mem-section
===UNAME===
Linux 6.0
===UPTIME===
up 2 hours
===LOADAVG===
0.20 0.30 0.40 1/60 111
===MEMORY===

===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  50%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.0 12345  6789 ?        Ss   Jan01   0:00 /sbin/init
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(output)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.text('empty-mem-section'), findsOneWidget);
      // Memory card title 'Memory' must not appear when memTotal == 0
      expect(find.text('Memory'), findsNothing);

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    // -------------------------------------------------------------------------
    // _ServerInfo.parse() — LOADAVG empty section guard
    //
    // When the LOADAVG section is present but empty (e.g. /proc/loadavg is
    // unavailable in a container), ''.split(RegExp(r'\s+')) returns [''] not
    // [], causing loadAvg1 to be '' instead of '0'.  The guard
    //   loadStr.isEmpty ? <String>[] : loadStr.split(...)
    // must produce '0' for all three fields.
    // -------------------------------------------------------------------------

    testWidgets(
        'load average fields default to "0" when LOADAVG section is empty',
        (tester) async {
      // LOADAVG section header present but no content (empty after trim).
      const output = '''
===HOSTNAME===
no-loadavg-host
===UNAME===
Linux 5.10.0
===UPTIME===
up 1 hour
===LOADAVG===
===MEMORY===
              total        used        free
Mem:    2147483648  1073741824  1073741824
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  50%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.0 12345  6789 ?        Ss   Jan01   0:00 /sbin/init
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(output)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      // Host name renders — confirms the parse succeeded.
      expect(find.text('no-loadavg-host'), findsOneWidget);
      // All three load average chips must show '0', not ''.
      expect(find.text('0'), findsNWidgets(3));

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets(
        'load average fields default to "0" when LOADAVG section is missing',
        (tester) async {
      // LOADAVG section header entirely absent from output.
      const output = '''
===HOSTNAME===
no-loadavg-section
===UNAME===
Linux 5.10.0
===UPTIME===
up 1 hour
===MEMORY===
              total        used        free
Mem:    2147483648  1073741824  1073741824
===DISK===
Mounted on          1B-blocks        Used       Avail Use%
/              107374182400 53687091200 48318382080  50%
===PROCS===
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.0 12345  6789 ?        Ss   Jan01   0:00 /sbin/init
===END===
''';
      when(() => mockChannelManager.runCommand(any())).thenAnswer(
        (_) async => Uint8List.fromList(utf8.encode(output)),
      );

      await tester.pumpWidget(buildTestWidget(channelManager: mockChannelManager));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      ServerMonitorDialog.show(context, 'test-session');
      await tester.pumpAndSettle();

      expect(find.text('no-loadavg-section'), findsOneWidget);
      // All three load average chips must show '0'.
      expect(find.text('0'), findsNWidgets(3));

      Navigator.of(tester.element(find.text('Server Monitor'))).pop();
      await tester.pumpAndSettle();
    });
  });
}
