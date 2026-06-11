import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/core/platform/detached_session_args.dart';

void main() {
  group('DetachedSessionArgs.tryParse', () {
    String b64(String s) => base64.encode(utf8.encode(s));

    test('parses valid detach arguments', () {
      final args = DetachedSessionArgs.tryParse([
        '--detach-connection-id=5',
        '--detach-tmux-b64=${b64('malme-3')}',
      ]);
      expect(args, isNotNull);
      expect(args!.connectionId, 5);
      expect(args.tmuxSessionName, 'malme-3');
    });

    test('tmux session name with spaces and unicode round-trips', () {
      final args = DetachedSessionArgs.tryParse([
        '--detach-connection-id=1',
        '--detach-tmux-b64=${b64('日本語 セッション "quoted"')}',
      ]);
      expect(args!.tmuxSessionName, '日本語 セッション "quoted"');
    });

    test('returns null for normal launch (no args)', () {
      expect(DetachedSessionArgs.tryParse([]), isNull);
    });

    test('returns null when connection id is missing', () {
      expect(
        DetachedSessionArgs.tryParse(['--detach-tmux-b64=${b64('x')}']),
        isNull,
      );
    });

    test('returns null when tmux name is missing', () {
      expect(
        DetachedSessionArgs.tryParse(['--detach-connection-id=2']),
        isNull,
      );
    });

    test('returns null for malformed base64', () {
      expect(
        DetachedSessionArgs.tryParse([
          '--detach-connection-id=2',
          '--detach-tmux-b64=%%%not-base64%%%',
        ]),
        isNull,
      );
    });

    test('returns null for non-numeric connection id', () {
      expect(
        DetachedSessionArgs.tryParse([
          '--detach-connection-id=abc',
          '--detach-tmux-b64=${b64('x')}',
        ]),
        isNull,
      );
    });

    test('ignores unrelated arguments', () {
      final args = DetachedSessionArgs.tryParse([
        '--enable-dart-profiling',
        '--detach-connection-id=3',
        '--detach-tmux-b64=${b64('work')}',
        '--other-flag',
      ]);
      expect(args!.connectionId, 3);
      expect(args.tmuxSessionName, 'work');
    });
  });
}
