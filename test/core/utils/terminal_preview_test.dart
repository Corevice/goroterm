import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/utils/terminal_preview.dart';

void main() {
  group('isChromeLine', () {
    test('blank / separators / borders are chrome', () {
      expect(isChromeLine(''), isTrue);
      expect(isChromeLine('   '), isTrue);
      expect(isChromeLine('────────────────────'), isTrue);
      expect(isChromeLine('╭──────────────────╮'), isTrue);
      expect(isChromeLine('│ >                │'), isTrue);
      expect(isChromeLine('╰──────────────────╯'), isTrue);
    });

    test('Claude UI hint/status lines are chrome', () {
      expect(isChromeLine('⏵⏵ bypass permissions on (shift+tab to cycle)'),
          isTrue);
      expect(isChromeLine('❯ Try "write a test for foo.dart"'), isTrue);
      expect(isChromeLine('? for shortcuts'), isTrue);
      expect(isChromeLine('esc to interrupt'), isTrue);
    });

    test('real content lines are not chrome', () {
      expect(isChromeLine('I added the login endpoint and 3 tests.'), isFalse);
      expect(isChromeLine('ログイン API を追加しました。'), isFalse);
      expect(isChromeLine('Should I also wire up the logout route?'), isFalse);
    });
  });

  group('extractNotificationPreview', () {
    test('picks the last meaningful content lines above the input box', () {
      final screen = [
        '  ▐▛███▜▌   Claude Code v2.1.195',
        '',
        'I implemented the change:',
        ' • Added POST /login returning a JWT',
        ' • Wrote 3 unit tests, all passing',
        'Want me to add rate limiting next?',
        '',
        '╭────────────────────────────────────╮',
        '│ >                                  │',
        '╰────────────────────────────────────╯',
        '⏵⏵ bypass permissions on (shift+tab to cycle) · ⏵ for agents',
        '❯ Try "write a test for foo.dart"',
      ];
      final preview = extractNotificationPreview(screen);
      expect(preview, isNotNull);
      // Claude の本文が上から順に含まれ、UI 装飾は含まれない
      expect(preview, contains('I implemented the change:'));
      expect(preview, contains('Added POST /login returning a JWT'));
      expect(preview, contains('Want me to add rate limiting next?'));
      expect(preview, isNot(contains('bypass permissions')));
      expect(preview, isNot(contains('Try "')));
      expect(preview, isNot(contains('╭')));
      // 上から順（実装→質問）に並ぶ
      expect(preview!.indexOf('I implemented'),
          lessThan(preview.indexOf('rate limiting')));
    });

    test('handles Japanese content', () {
      final screen = [
        'テストを追加しました。',
        '次はデプロイしますか？',
        '╭─────────╮',
        '│ >       │',
        '╰─────────╯',
        '? for shortcuts',
      ];
      final preview = extractNotificationPreview(screen);
      expect(preview, contains('テストを追加しました。'));
      expect(preview, contains('次はデプロイしますか？'));
    });

    test('returns null when there is no meaningful content', () {
      final screen = [
        '╭─────────╮',
        '│ >       │',
        '╰─────────╯',
        '   ',
        '────────',
      ];
      expect(extractNotificationPreview(screen), isNull);
    });

    test('truncates very long previews', () {
      final long = List.generate(20, (i) => 'This is content line number $i.');
      final preview = extractNotificationPreview(long, maxChars: 100);
      expect(preview!.length, lessThanOrEqualTo(101)); // +1 for the ellipsis
      expect(preview.endsWith('…'), isTrue);
    });

    test('caps the number of picked lines', () {
      final many = List.generate(30, (i) => 'meaningful content line $i here');
      final preview = extractNotificationPreview(many, maxLines: 4);
      expect(preview!.split('\n').length, 4);
    });
  });
}
