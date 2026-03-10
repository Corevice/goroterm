import 'package:flutter_test/flutter_test.dart';
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
// ---------------------------------------------------------------------------

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
}
