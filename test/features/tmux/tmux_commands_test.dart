import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_commands.dart';

void main() {
  group('buildTmuxAttachCommand', () {
    test('attach-or-create via new-session -A with shell-quoted name', () {
      expect(
        buildTmuxAttachCommand('work'),
        " tmux new-session -A -s 'work'\r",
      );
    });

    // シェル履歴汚染防止: 先頭の半角スペースで、
    // HISTCONTROL=ignorespace/ignoreboth (bash) や HIST_IGNORE_SPACE (zsh)
    // のシェルが履歴に記録しないようにする。
    test('starts with a space so it is excluded from shell history', () {
      final cmd = buildTmuxAttachCommand('my-session');
      expect(cmd.startsWith(' '), isTrue,
          reason: 'leading space keeps the attach command out of shell history');
      // スペースは 1 つだけ (`  tmux` のような二重スペースにしない)
      expect(cmd.startsWith('  '), isFalse);
    });

    test('ends with a carriage return to execute the command', () {
      expect(buildTmuxAttachCommand('x').endsWith('\r'), isTrue);
    });

    test('shell-escapes names with spaces and quotes', () {
      expect(
        buildTmuxAttachCommand('my session'),
        " tmux new-session -A -s 'my session'\r",
      );
      expect(
        buildTmuxAttachCommand("it's"),
        r" tmux new-session -A -s 'it'\''s'" '\r',
      );
    });
  });
}
