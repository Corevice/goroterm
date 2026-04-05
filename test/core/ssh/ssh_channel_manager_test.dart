import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/error/app_error.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_channel_manager.dart';
import 'package:terminal_ssh_app/core/utils/shell_utils.dart';

// ---------------------------------------------------------------------------
// SshChannelManager — unit-level tests
//
// The SSH channel operations (openPtyChannel, executeCommand, etc.) require a
// live SSHClient and cannot be exercised without a real SSH server or a very
// heavy mock. Those paths are covered by integration tests.
//
// What we CAN test here:
//   • The shell-quoting logic used by openExecStream and getTmuxPaneCwd.
//     Both methods delegate to shellQuote(), so verifying shellQuote()'s
//     output for their specific inputs is equivalent to verifying the
//     command strings those methods will produce.
//   • The _readAbsolutePath output-validation logic via fake SSHClient/Session:
//       – valid absolute path is returned as-is
//       – empty output → null
//       – relative (non-'/' prefix) output → null
//       – execute() throwing → null
//       – session.close() always called (no resource leak)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Fakes for _readAbsolutePath tests
// ---------------------------------------------------------------------------

/// Fake SSHSession whose stdout emits [output] once.
/// Tracks whether [close()] was called.
class _StubSession extends Fake implements SSHSession {
  _StubSession(String output)
      : _stdout =
            Stream.value(Uint8List.fromList(utf8.encode(output)));

  final Stream<Uint8List> _stdout;
  bool closeCalled = false;

  @override
  Stream<Uint8List> get stdout => _stdout;

  @override
  void close() => closeCalled = true;
}

/// Fake SSHClient that delegates execute() to a provided factory.
/// Named parameters from the real SSHClient.execute() are accepted but ignored.
class _StubClient extends Fake implements SSHClient {
  _StubClient(this._factory);
  final SSHSession Function(String command) _factory;

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async =>
      _factory(command);
}

/// Fake SSHClient whose execute() always throws.
class _ThrowingClient extends Fake implements SSHClient {
  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) =>
      Future.error(Exception('execute failed'));
}

/// Fake SSHClient whose shell() always throws.
class _ShellThrowingClient extends Fake implements SSHClient {
  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) =>
      Future.error(Exception('shell failed'));
}

/// Fake SSHSession that tracks close() and resizeTerminal() calls.
class _FakePtySession extends Fake implements SSHSession {
  bool closeCalled = false;
  final List<(int, int)> resizeCalls = [];

  @override
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  void close() => closeCalled = true;

  @override
  void resizeTerminal(int width, int height, [int pixelWidth = 0, int pixelHeight = 0]) =>
      resizeCalls.add((width, height));
}

/// Fake SSHClient whose shell() returns a provided [_FakePtySession].
class _FakeShellClient extends Fake implements SSHClient {
  _FakeShellClient(this.session);
  final _FakePtySession session;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async =>
      session;
}

/// Fake SSHClient whose run() always throws.
class _RunThrowingClient extends Fake implements SSHClient {
  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) =>
      Future.error(Exception('run failed'));
}

/// Fake SSHClient whose shell() captures the SSHPtyConfig for later inspection.
class _CapturingShellClient extends Fake implements SSHClient {
  _CapturingShellClient(this._session);
  final _FakePtySession _session;
  SSHPtyConfig? capturedPty;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async {
    capturedPty = pty;
    return _session;
  }
}

/// Fake SSHClient whose run() returns a fixed Uint8List.
class _FakeRunClient extends Fake implements SSHClient {
  _FakeRunClient(this._result);
  final Uint8List _result;

  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async =>
      _result;
}

/// Fake SSHClient that combines shell() and sftp() support for tests that
/// need to open both a PTY channel and an SFTP channel on the same manager.
class _CombinedFakeClient extends Fake implements SSHClient {
  _CombinedFakeClient({required this.ptySession, required this.sftpCounter});
  final _FakePtySession ptySession;
  final _SftpCountingClient sftpCounter;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async =>
      ptySession;

  @override
  Future<SftpClient> sftp() => sftpCounter.sftp();
}

/// Fake SSHClient whose sftp() always throws.
class _SftpThrowingClient extends Fake implements SSHClient {
  @override
  Future<SftpClient> sftp() => Future.error(Exception('sftp failed'));
}

/// Fake SSHClient whose sftp() succeeds on the first call then throws on all
/// subsequent calls. Used to exercise the re-open failure path in
/// openSftpChannel(), where the previous client must be closed despite the
/// error.
class _SftpSucceedOnceThenThrowClient extends Fake implements SSHClient {
  final _FakeSftpClient firstClient = _FakeSftpClient();
  int _calls = 0;

  @override
  Future<SftpClient> sftp() async {
    _calls++;
    if (_calls == 1) return firstClient;
    throw Exception('sftp failed on second call');
  }
}

/// Fake SftpClient that tracks whether close() was called.
class _FakeSftpClient extends Fake implements SftpClient {
  bool closeCalled = false;

  @override
  void close() => closeCalled = true;
}

/// Fake SSHClient that creates a new [_FakeSftpClient] on each sftp() call.
/// All created instances are accessible via [created].
class _SftpCountingClient extends Fake implements SSHClient {
  final List<_FakeSftpClient> created = [];

  @override
  Future<SftpClient> sftp() async {
    final fake = _FakeSftpClient();
    created.add(fake);
    return fake;
  }
}

/// Fake SSHSession whose stdout stream is controlled by the caller and never
/// emits spontaneously. Used to exercise the 5-second timeout in
/// _readAbsolutePath: by advancing time with fakeAsync the timeout fires,
/// resolving the call with null without the stream ever completing.
class _HangingSession extends Fake implements SSHSession {
  _HangingSession() : _controller = StreamController<Uint8List>();

  final StreamController<Uint8List> _controller;
  bool closeCalled = false;

  @override
  Stream<Uint8List> get stdout => _controller.stream;

  @override
  void close() => closeCalled = true;

  void dispose() {
    if (!_controller.isClosed) _controller.close();
  }
}

void main() {
  // -------------------------------------------------------------------------
  // shellQuote — command-string construction for openExecStream
  // -------------------------------------------------------------------------

  group('openExecStream command format', () {
    // openExecStream builds: "cat ${shellQuote(remotePath)}"
    // These tests document which remotePath values produce safe cat commands.

    test('simple path produces cat with single-quoted argument', () {
      final cmd = 'cat ${shellQuote('/home/user/file.txt')}';
      expect(cmd, "cat '/home/user/file.txt'");
    });

    test('path with spaces is correctly quoted', () {
      final cmd = 'cat ${shellQuote('/home/user/my docs/file.txt')}';
      expect(cmd, "cat '/home/user/my docs/file.txt'");
    });

    test('path with single quote is escaped', () {
      final cmd = "cat ${shellQuote("/home/user/o'clock/log.txt")}";
      expect(cmd, r"cat '/home/user/o'\''clock/log.txt'");
    });

    test('path with shell metacharacters is safely quoted', () {
      final cmd = 'cat ${shellQuote('/tmp/\$(rm -rf /)/')}';
      expect(cmd, "cat '/tmp/\$(rm -rf /)/'");
    });

    test('path with dollar sign is quoted verbatim (not expanded)', () {
      final cmd = 'cat ${shellQuote('/home/\$USER/notes.txt')}';
      expect(cmd, "cat '/home/\$USER/notes.txt'");
    });

    test('path with backtick is quoted verbatim', () {
      final cmd = 'cat ${shellQuote('/tmp/`id`/x')}';
      expect(cmd, "cat '/tmp/`id`/x'");
    });

    test('path with semicolon is quoted verbatim', () {
      final cmd = 'cat ${shellQuote('/tmp/a;b')}';
      expect(cmd, "cat '/tmp/a;b'");
    });

    test('empty path produces empty single-quoted argument', () {
      final cmd = 'cat ${shellQuote('')}';
      expect(cmd, "cat ''");
    });
  });

  // -------------------------------------------------------------------------
  // shellQuote — command-string construction for getTmuxPaneCwd
  // -------------------------------------------------------------------------

  group('getTmuxPaneCwd command format', () {
    // getTmuxPaneCwd builds:
    //   "tmux display-message -p -t ${shellQuote(name)} '#{pane_current_path}' 2>/dev/null"

    String buildTmuxCmd(String sessionName) =>
        "tmux display-message -p -t ${shellQuote(sessionName)} "
        "'#{pane_current_path}' 2>/dev/null";

    test('simple session name is single-quoted', () {
      expect(
        buildTmuxCmd('main'),
        "tmux display-message -p -t 'main' '#{pane_current_path}' 2>/dev/null",
      );
    });

    test('session name with spaces is safely quoted', () {
      expect(
        buildTmuxCmd('my session'),
        "tmux display-message -p -t 'my session' '#{pane_current_path}' 2>/dev/null",
      );
    });

    test('session name with single quote is escaped', () {
      expect(
        buildTmuxCmd("dev's"),
        r"tmux display-message -p -t 'dev'\''s' '#{pane_current_path}' 2>/dev/null",
      );
    });

    test('session name with colon (tmux:window syntax) is quoted', () {
      expect(
        buildTmuxCmd('work:1'),
        "tmux display-message -p -t 'work:1' '#{pane_current_path}' 2>/dev/null",
      );
    });

    test('session name with dollar sign is quoted verbatim', () {
      expect(
        buildTmuxCmd('\$SESSION'),
        "tmux display-message -p -t '\$SESSION' '#{pane_current_path}' 2>/dev/null",
      );
    });
  });

  // -------------------------------------------------------------------------
  // getShellCwd — command string sent to execute()
  //
  // getShellCwd() builds a multi-stage shell pipeline that uses $PPID, ps,
  // awk, grep, and readlink to find the PTY shell's CWD.  This group pins the
  // exact command string so accidental edits to the pipeline are caught
  // immediately, independent of what the remote host returns.
  // -------------------------------------------------------------------------

  group('getShellCwd command format', () {
    // The expected command is the verbatim concatenation of the raw-string
    // literals in SshChannelManager.getShellCwd().
    const expectedGetShellCwdCommand =
        r"CWD=$(readlink /proc/$(ps --no-headers -o pid,ppid,tty,comm -u $(whoami) "
        r"| awk -v ppid=$PPID "
        r"'$2==ppid && $3 ~ /pts\// && $4 ~ /bash|zsh|fish|sh$/ {print $1; exit}'"
        r")/cwd 2>/dev/null); "
        r'if [ -n "$CWD" ]; then echo "$CWD"; else '
        r"readlink /proc/$(ps --no-headers -u $(whoami) -o pid,tty,comm "
        r"| grep 'pts/' | grep -E 'bash|zsh|fish|sh$' "
        r"| tail -1 | awk '{print $1}')/cwd 2>/dev/null; fi";

    test('sends the expected multi-stage pipeline to execute()', () async {
      String? capturedCommand;
      final stub = _StubSession('/home/user');
      final manager = SshChannelManager(
        client: _StubClient((cmd) {
          capturedCommand = cmd;
          return stub;
        }),
      );

      await manager.getShellCwd();

      expect(capturedCommand, expectedGetShellCwdCommand);
    });

    test('command contains PPID-based primary lookup', () {
      expect(
        expectedGetShellCwdCommand,
        contains(r'awk -v ppid=$PPID'),
      );
      expect(
        expectedGetShellCwdCommand,
        contains(r'$2==ppid'),
      );
    });

    test('command contains pts/ tty filter', () {
      expect(
        expectedGetShellCwdCommand,
        contains(r"$3 ~ /pts\//"),
      );
    });

    test('command contains shell-name filter covering bash zsh fish sh', () {
      expect(
        expectedGetShellCwdCommand,
        contains(r'bash|zsh|fish|sh$'),
      );
    });

    test('command contains tail-1 fallback for non-PPID environments', () {
      expect(
        expectedGetShellCwdCommand,
        contains('tail -1'),
      );
    });

    test('command uses readlink on /proc cwd for both paths', () {
      final matches = RegExp(r'readlink /proc/').allMatches(expectedGetShellCwdCommand);
      expect(matches.length, 2,
          reason: 'primary and fallback both use readlink /proc/…/cwd');
    });
  });

  // -------------------------------------------------------------------------
  // _readAbsolutePath output-validation (via getShellCwd / getTmuxPaneCwd)
  //
  // These tests exercise the path returned by the remote command:
  //   • valid absolute path → returned as-is
  //   • empty output       → null
  //   • relative path      → null
  //   • execute() throws   → null
  //   • session.close()    → always called (no SSH channel leak)
  // -------------------------------------------------------------------------

  group('getShellCwd _readAbsolutePath output validation', () {
    test('returns absolute path when output starts with /', () async {
      final stub = _StubSession('/home/user/projects');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      expect(await manager.getShellCwd(), '/home/user/projects');
    });

    test('strips trailing whitespace/newline from the path', () async {
      final stub = _StubSession('/var/log\n');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      expect(await manager.getShellCwd(), '/var/log');
    });

    test('returns null for empty output', () async {
      final stub = _StubSession('');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      expect(await manager.getShellCwd(), isNull);
    });

    test('returns null when output does not start with /', () async {
      final stub = _StubSession('relative/path');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      expect(await manager.getShellCwd(), isNull);
    });

    test('returns null when execute() throws', () async {
      final manager = SshChannelManager(client: _ThrowingClient());
      expect(await manager.getShellCwd(), isNull);
    });

    test('session.close() is called after successful read', () async {
      final stub = _StubSession('/home/user');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      await manager.getShellCwd();
      expect(stub.closeCalled, isTrue);
    });

    test('session.close() is called even when output is invalid', () async {
      final stub = _StubSession('not-a-path');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      await manager.getShellCwd();
      expect(stub.closeCalled, isTrue);
    });

    // _readAbsolutePath guards against a hung SSH channel with a 5-second
    // timeout. When the stdout stream never emits or closes, the timeout fires
    // and onTimeout returns '', which is treated as "no valid path" → null.
    test('returns null when stdout stream hangs past 5-second timeout', () {
      final session = _HangingSession();

      fakeAsync((async) {
        final manager = SshChannelManager(
          client: _StubClient((_) => session),
        );

        String? result;
        var done = false;
        manager.getShellCwd().then((v) {
          result = v;
          done = true;
        });

        // Just before timeout: must still be pending.
        async.elapse(const Duration(seconds: 4, milliseconds: 999));
        expect(done, isFalse,
            reason: 'should not complete before 5-second timeout');

        // Past the 5-second mark: onTimeout fires, returns '' → null.
        async.elapse(const Duration(seconds: 1));
        expect(done, isTrue,
            reason: 'should complete after timeout');
        expect(result, isNull,
            reason: 'empty onTimeout string must resolve to null');

        // The finally block must have closed the SSH session.
        expect(session.closeCalled, isTrue,
            reason: 'session.close() must be called in finally');
      });

      session.dispose();
    });
  });

  group('getTmuxPaneCwd _readAbsolutePath output validation', () {
    test('returns pane path when output starts with /', () async {
      final stub = _StubSession('/home/user/work');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      expect(await manager.getTmuxPaneCwd('main'), '/home/user/work');
    });

    test('returns null for empty output', () async {
      final stub = _StubSession('');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      expect(await manager.getTmuxPaneCwd('main'), isNull);
    });

    test('returns null when execute() throws', () async {
      final manager = SshChannelManager(client: _ThrowingClient());
      expect(await manager.getTmuxPaneCwd('main'), isNull);
    });

    test('session.close() is called after getTmuxPaneCwd', () async {
      final stub = _StubSession('/tmp');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );
      await manager.getTmuxPaneCwd('work');
      expect(stub.closeCalled, isTrue);
    });

    // _readAbsolutePath guards against a hung SSH channel with a 5-second
    // timeout. getTmuxPaneCwd shares the same implementation, so verify that
    // the timeout and session.close() also apply for the tmux command path.
    test('returns null when stdout stream hangs past 5-second timeout', () {
      final session = _HangingSession();

      fakeAsync((async) {
        final manager = SshChannelManager(
          client: _StubClient((_) => session),
        );

        String? result;
        var done = false;
        manager.getTmuxPaneCwd('main').then((v) {
          result = v;
          done = true;
        });

        // Just before timeout: must still be pending.
        async.elapse(const Duration(seconds: 4, milliseconds: 999));
        expect(done, isFalse,
            reason: 'should not complete before 5-second timeout');

        // Past the 5-second mark: onTimeout fires, returns '' → null.
        async.elapse(const Duration(seconds: 1));
        expect(done, isTrue,
            reason: 'should complete after timeout');
        expect(result, isNull,
            reason: 'empty onTimeout string must resolve to null');

        // The finally block must have closed the SSH session.
        expect(session.closeCalled, isTrue,
            reason: 'session.close() must be called in finally');
      });

      session.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // NetworkError wrapping
  //
  // openPtyChannel(), executeCommand(), runCommand(), openSftpChannel(), and
  // openExecStream() each catch SSH-level exceptions and re-throw them as
  // NetworkError so callers can handle them uniformly.
  // dispose() must not throw even when no sessions have been opened.
  // ---------------------------------------------------------------------------

  group('NetworkError wrapping', () {
    test('openPtyChannel() wraps shell() exception as NetworkError', () {
      final manager = SshChannelManager(client: _ShellThrowingClient());
      expect(
        () => manager.openPtyChannel(),
        throwsA(isA<NetworkError>()),
      );
    });

    test('executeCommand() wraps execute() exception as NetworkError', () {
      final manager = SshChannelManager(client: _ThrowingClient());
      expect(
        () => manager.executeCommand('echo hi'),
        throwsA(isA<NetworkError>()),
      );
    });

    test('runCommand() wraps run() exception as NetworkError', () {
      final manager = SshChannelManager(client: _RunThrowingClient());
      expect(
        () => manager.runCommand('echo hi'),
        throwsA(isA<NetworkError>()),
      );
    });

    test('openSftpChannel() wraps sftp() exception as NetworkError', () {
      final manager = SshChannelManager(client: _SftpThrowingClient());
      expect(
        () => manager.openSftpChannel(),
        throwsA(isA<NetworkError>()),
      );
    });

    test('openExecStream() wraps execute() exception as NetworkError', () {
      final manager = SshChannelManager(client: _ThrowingClient());
      expect(
        () => manager.openExecStream('/tmp/file.txt'),
        throwsA(isA<NetworkError>()),
      );
    });

    test('dispose() does not throw when no sessions are open', () {
      final manager = SshChannelManager(client: _ThrowingClient());
      expect(manager.dispose, returnsNormally);
    });

    test('openIndependentSftpChannel() wraps sftp() exception as NetworkError',
        () {
      final manager = SshChannelManager(client: _SftpThrowingClient());
      expect(
        () => manager.openIndependentSftpChannel(),
        throwsA(isA<NetworkError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // openIndependentSftpChannel — does not replace the shared _sftpClient
  //
  // The file browser holds a persistent SftpClient via openSftpChannel().
  // File uploads and other one-off operations must not overwrite that reference
  // so that dispose() still closes the correct channel.
  // ---------------------------------------------------------------------------

  group('openIndependentSftpChannel', () {
    test('returns a new SftpClient distinct from the one set by openSftpChannel()',
        () async {
      final countingClient = _SftpCountingClient();
      final manager = SshChannelManager(client: countingClient);

      final shared = await manager.openSftpChannel();
      final independent = await manager.openIndependentSftpChannel();

      expect(identical(shared, independent), isFalse,
          reason: 'independent channel must be a different object');
      expect(countingClient.created.length, 2,
          reason: 'sftp() should have been called twice');
    });

    test('dispose() closes the shared channel but not the independent one',
        () async {
      final countingClient = _SftpCountingClient();
      final manager = SshChannelManager(client: countingClient);

      await manager.openSftpChannel();           // sets _sftpClient = created[0]
      await manager.openIndependentSftpChannel(); // returns created[1], no assignment

      manager.dispose();

      expect(countingClient.created[0].closeCalled, isTrue,
          reason: 'shared _sftpClient must be closed by dispose()');
      expect(countingClient.created[1].closeCalled, isFalse,
          reason: 'independent channel is caller-owned; dispose() must not close it');
    });

    test('calling openIndependentSftpChannel() before openSftpChannel() leaves '
        '_sftpClient null so dispose() does not close it', () async {
      final countingClient = _SftpCountingClient();
      final manager = SshChannelManager(client: countingClient);

      await manager.openIndependentSftpChannel(); // returns created[0]

      // dispose() should be a no-op for _sftpClient (it was never set)
      expect(manager.dispose, returnsNormally);
      expect(countingClient.created[0].closeCalled, isFalse,
          reason: 'independent channel must not be closed by dispose()');
    });
  });

  // ---------------------------------------------------------------------------
  // openSftpChannel — previous SftpClient closed on re-open
  //
  // Calling openSftpChannel() a second time replaces _sftpClient. The previous
  // client must be closed to avoid leaking the underlying SSH channel.
  // ---------------------------------------------------------------------------

  group('openSftpChannel re-open closes previous client', () {
    test('previous SftpClient is closed when openSftpChannel() is called again',
        () async {
      final countingClient = _SftpCountingClient();
      final manager = SshChannelManager(client: countingClient);

      await manager.openSftpChannel(); // created[0] becomes _sftpClient
      await manager.openSftpChannel(); // created[1] replaces it; created[0] must be closed

      expect(countingClient.created[0].closeCalled, isTrue,
          reason: 'first SftpClient must be closed when replaced');
      expect(countingClient.created[1].closeCalled, isFalse,
          reason: 'current SftpClient must remain open');
    });

    test('dispose() closes the latest SftpClient after re-open', () async {
      final countingClient = _SftpCountingClient();
      final manager = SshChannelManager(client: countingClient);

      await manager.openSftpChannel(); // created[0]
      await manager.openSftpChannel(); // created[1]
      manager.dispose();

      expect(countingClient.created[1].closeCalled, isTrue,
          reason: 'dispose() must close the current (second) SftpClient');
    });

    test('first openSftpChannel() call (no previous) does not throw', () async {
      final countingClient = _SftpCountingClient();
      final manager = SshChannelManager(client: countingClient);

      await expectLater(manager.openSftpChannel(), completes);
      expect(countingClient.created.length, 1);
    });

    test('previous SftpClient is closed when re-open throws NetworkError',
        () async {
      final client = _SftpSucceedOnceThenThrowClient();
      final manager = SshChannelManager(client: client);

      await manager.openSftpChannel(); // first call succeeds

      await expectLater(
        manager.openSftpChannel(), // second call throws
        throwsA(isA<NetworkError>()),
      );

      expect(client.firstClient.closeCalled, isTrue,
          reason: 'previous SftpClient must be closed even when re-open throws');
    });
  });

  // ---------------------------------------------------------------------------
  // dispose() — PTY session lifecycle
  //
  // dispose() must close _ptySession when it has been opened, and must handle
  // both _ptySession and _sftpClient being open at the same time.
  // ---------------------------------------------------------------------------

  group('dispose() closes _ptySession', () {
    test('dispose() calls close() on _ptySession after openPtyChannel()',
        () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));

      await manager.openPtyChannel();
      manager.dispose();

      expect(pty.closeCalled, isTrue,
          reason: 'dispose() must close the PTY session');
    });

    test('dispose() closes both _ptySession and _sftpClient when both are open',
        () async {
      final pty = _FakePtySession();
      final countingClient = _SftpCountingClient();

      // We need a client that supports both shell() and sftp().
      // Since _FakeShellClient and _SftpCountingClient are separate stubs,
      // build a combined fake inline.
      final combined = _CombinedFakeClient(ptySession: pty, sftpCounter: countingClient);
      final manager = SshChannelManager(client: combined);

      await manager.openPtyChannel();
      await manager.openSftpChannel();
      manager.dispose();

      expect(pty.closeCalled, isTrue,
          reason: 'dispose() must close the PTY session');
      expect(countingClient.created[0].closeCalled, isTrue,
          reason: 'dispose() must close the shared SftpClient');
    });

    test('dispose() after openPtyChannel() nullifies the ptySession getter',
        () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));

      await manager.openPtyChannel();
      expect(manager.ptySession, isNotNull);

      manager.dispose();
      expect(manager.ptySession, isNull,
          reason: 'ptySession getter must return null after dispose()');
    });
  });

  // ---------------------------------------------------------------------------
  // resizePty() — delegates to SSHSession.resizeTerminal()
  //
  // resizePty() must forward width/height to the active PTY session, and must
  // be a no-op (not throw) when no PTY session has been opened.
  // ---------------------------------------------------------------------------

  group('resizePty()', () {
    test('delegates width and height to resizeTerminal() on the active session',
        () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));

      await manager.openPtyChannel();
      manager.resizePty(120, 40);

      expect(pty.resizeCalls, [(120, 40)],
          reason: 'resizePty() must forward dimensions to resizeTerminal()');
    });

    test('multiple resizePty() calls all reach the session', () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));

      await manager.openPtyChannel();
      manager.resizePty(80, 24);
      manager.resizePty(132, 50);

      expect(pty.resizeCalls, [(80, 24), (132, 50)]);
    });

    test('resizePty() is a no-op when no PTY session is open', () {
      final manager = SshChannelManager(client: _ShellThrowingClient());
      expect(() => manager.resizePty(80, 24), returnsNormally,
          reason: 'resizePty() must not throw when _ptySession is null');
    });

    test('resizePty() is a no-op after dispose()', () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));

      await manager.openPtyChannel();
      manager.dispose();
      // After dispose() _ptySession is null; resizePty() must not throw.
      expect(() => manager.resizePty(80, 24), returnsNormally);
    });

    test('resizePty() ignores zero or negative dimensions', () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));

      await manager.openPtyChannel();
      manager.resizePty(0, 24);
      manager.resizePty(80, 0);
      manager.resizePty(-1, 24);
      manager.resizePty(80, -1);

      expect(pty.resizeCalls, isEmpty,
          reason: 'non-positive dimensions must never reach resizeTerminal()');
    });
  });

  // ---------------------------------------------------------------------------
  // openPtyChannel() — SSHPtyConfig dimension forwarding
  //
  // The width/height defaults (80×24) and any caller-specified values must be
  // forwarded verbatim to SSHPtyConfig so that the remote terminal is sized
  // correctly from the very first keystroke.
  // ---------------------------------------------------------------------------

  group('openPtyChannel() dimension forwarding', () {
    test('uses default 80×24 when no dimensions are specified', () async {
      final pty = _FakePtySession();
      final capturing = _CapturingShellClient(pty);
      final manager = SshChannelManager(client: capturing);

      await manager.openPtyChannel();

      expect(capturing.capturedPty?.width, 80,
          reason: 'default width must be 80');
      expect(capturing.capturedPty?.height, 24,
          reason: 'default height must be 24');
    });

    test('forwards custom width and height to SSHPtyConfig', () async {
      final pty = _FakePtySession();
      final capturing = _CapturingShellClient(pty);
      final manager = SshChannelManager(client: capturing);

      await manager.openPtyChannel(width: 132, height: 50);

      expect(capturing.capturedPty?.width, 132,
          reason: 'custom width must reach SSHPtyConfig');
      expect(capturing.capturedPty?.height, 50,
          reason: 'custom height must reach SSHPtyConfig');
    });

    test('sets terminal type to xterm-256color', () async {
      final pty = _FakePtySession();
      final capturing = _CapturingShellClient(pty);
      final manager = SshChannelManager(client: capturing);

      await manager.openPtyChannel();

      expect(capturing.capturedPty?.type, 'xterm-256color',
          reason: 'terminal type must be xterm-256color for colour support');
    });
  });

  // ---------------------------------------------------------------------------
  // executeCommand() and runCommand() — success paths
  //
  // Verifies that the happy-path return value (SSHSession / Uint8List) passes
  // through from the underlying SSHClient without modification.
  // ---------------------------------------------------------------------------

  group('executeCommand() and runCommand() success paths', () {
    test('executeCommand() returns the SSHSession produced by execute()', () async {
      final stub = _StubSession('');
      final manager = SshChannelManager(
        client: _StubClient((_) => stub),
      );

      final result = await manager.executeCommand('echo hello');

      expect(identical(result, stub), isTrue,
          reason: 'executeCommand() must return the same session object');
    });

    test('runCommand() returns the Uint8List produced by run()', () async {
      final expected = Uint8List.fromList([72, 101, 108, 108, 111]); // "Hello"
      final manager = SshChannelManager(client: _FakeRunClient(expected));

      final result = await manager.runCommand('echo Hello');

      expect(result, equals(expected),
          reason: 'runCommand() must return the raw bytes from run()');
    });
  });

  // ---------------------------------------------------------------------------
  // dispose() — idempotency
  //
  // Calling dispose() a second time must be a no-op: the sessions have already
  // been nullified, so there is nothing to close and nothing should throw.
  // ---------------------------------------------------------------------------

  group('dispose() idempotency', () {
    test('dispose() called twice does not throw', () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));

      await manager.openPtyChannel();
      manager.dispose();

      expect(manager.dispose, returnsNormally,
          reason: 'second dispose() must be a safe no-op');
    });

    test('ptySession getter returns null after double dispose()', () async {
      final pty = _FakePtySession();
      final manager = SshChannelManager(client: _FakeShellClient(pty));

      await manager.openPtyChannel();
      manager.dispose();
      manager.dispose();

      expect(manager.ptySession, isNull,
          reason: '_ptySession must remain null after second dispose()');
    });
  });
}
