import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/utils/claude_rc_setup.dart';

void main() {
  group('claudeRcPathIsSet', () {
    test('null / empty / whitespace are unset', () {
      expect(claudeRcPathIsSet(null), isFalse);
      expect(claudeRcPathIsSet(''), isFalse);
      expect(claudeRcPathIsSet('   '), isFalse);
    });
    test('a real path is set', () {
      expect(claudeRcPathIsSet('~/.claude/CLAUDE-FABLE-5'), isTrue);
    });
  });

  group('buildClaudeRcSetupCommand — unset', () {
    test('returns a removal-only command (no append/printf)', () {
      final cmd = buildClaudeRcSetupCommand(null);
      expect(cmd, contains('grep -q'));
      expect(cmd, contains('>>> goroterm claude >>>'));
      // 未設定では関数の追記は行わない
      expect(cmd, isNot(contains('printf')));
      expect(cmd, isNot(contains('--system-prompt-file')));
    });

    test('empty string behaves like unset', () {
      expect(buildClaudeRcSetupCommand('  '),
          equals(buildClaudeRcSetupCommand(null)));
    });
  });

  group('buildClaudeRcSetupCommand — set', () {
    test('defines a claude wrapper with --system-prompt-file', () {
      final cmd = buildClaudeRcSetupCommand('~/.claude/CLAUDE-FABLE-5');
      expect(cmd, contains('claude() {'));
      expect(cmd, contains('command claude --system-prompt-file'));
      expect(cmd, contains(r'"$@"'));
      // 両方の rc を走査
      expect(cmd, contains(r'$HOME/.bashrc'));
      expect(cmd, contains(r'$HOME/.zshrc'));
      // 既存ブロックを除去してから追記する
      expect(cmd, contains('printf'));
      expect(cmd, contains('>>> goroterm claude >>>'));
      expect(cmd, contains('<<< goroterm claude <<<'));
    });

    test('leading ~/ is normalized to \$HOME so it expands at runtime', () {
      final cmd = buildClaudeRcSetupCommand('~/.claude/CLAUDE-FABLE-5');
      expect(cmd, contains(r'$HOME/.claude/CLAUDE-FABLE-5'));
      // 生の ~ は残さない
      expect(cmd, isNot(contains('"~/.claude')));
    });

    test('absolute path is kept as-is', () {
      final cmd = buildClaudeRcSetupCommand('/etc/claude/sys.md');
      expect(cmd, contains('/etc/claude/sys.md'));
    });

    test('falls back to plain claude when the file is missing', () {
      final cmd = buildClaudeRcSetupCommand('~/.claude/CLAUDE-FABLE-5');
      // -f ガードと else 分岐（素の claude）を含む
      expect(cmd, contains(r'if [ -f "$HOME/.claude/CLAUDE-FABLE-5" ]'));
      expect(cmd, contains(r'else command claude "$@"'));
    });

    test('double quotes / backticks in the path are escaped', () {
      final cmd = buildClaudeRcSetupCommand(r'/tmp/a"b`c');
      expect(cmd, contains(r'\"'));
      expect(cmd, contains(r'\`'));
      // ダブルクォートが未エスケープで関数を壊さない
      expect(cmd, isNot(contains('"/tmp/a"b')));
    });
  });
}
