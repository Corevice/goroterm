import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('can parse window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[8;24;80t');
      verify(parser.handler.resize(80, 24));
    });

    test('consumes DCS payload and parses following CSI (ST terminator)', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);
      // DCS = 2026 h ST (Synchronized Output Mode begin), then CSI H
      parser.write('\x1bP=2026h\x1b\\\x1b[H');
      verify(handler.setCursor(0, 0));
    });

    test('consumes DCS payload and parses following CSI (BEL terminator)', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);
      parser.write('\x1bPfoo\x07\x1b[H');
      verify(handler.setCursor(0, 0));
    });

    test('OSC 52 decodes base64 clipboard payload and calls setClipboardData',
        () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);
      // "hello" base64 -> aGVsbG8=
      parser.write('\x1b]52;c;aGVsbG8=\x07');
      verify(handler.setClipboardData('hello'));
    });

    test('OSC 52 query payload (?) is ignored', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);
      parser.write('\x1b]52;c;?\x07');
      verifyNever(handler.setClipboardData(any));
    });
  });

  group('DCS payload with embedded ESC', () {
    // tmux passthrough (`ESC P tmux; ... ESC \`) はペイロード内の ESC を
    // 二重化 (ESC ESC) する。ESC+任意文字で終端扱いすると残りの
    // ペイロードが平文として画面に漏れる。
    test('tmux passthrough payload (doubled ESC) does not leak as text', () {
      final terminal = _makeTerminal();
      // Claude Code が $TMUX 検出時に実際に送る背景色クエリと同形
      terminal.write('before|\x1bPtmux;\x1b\x1b]11;?\x07\x1b\\|after');
      expect(_screenText(terminal), 'before||after');
    });

    test('tmux passthrough split across writes does not leak as text', () {
      final terminal = _makeTerminal();
      terminal.write('before|');
      terminal.write('\x1bPtmux;\x1b'); // 二重化 ESC の途中で分断
      terminal.write('\x1b]52;c;aGVsbG8=\x07\x1b\\');
      terminal.write('|after');
      expect(_screenText(terminal), 'before||after');
    });

    // 上限未満の未終端 DCS は引き続き終端を待つ（rollback 機構）。
    test('incomplete DCS below the cap still waits for its terminator', () {
      final terminal = _makeTerminal();
      terminal.write('before|');
      terminal.write('\x1bPq#####'); // 終端なし・上限未満
      expect(_screenText(terminal), 'before|',
          reason: 'payload must not appear while DCS is pending');
      terminal.write('\x1b\\|after');
      expect(_screenText(terminal), 'before||after');
    });
  });

  group('unterminated sequence length cap', () {
    // 終端が来ないシーケンスは上限到達で打ち切られ、後続の出力が流れ続ける。
    // 以前は write のたびに保留分全体を再スキャンして O(n²) になり、
    // 終端が永遠に来ない場合は以降の出力を全て飲み込んでいた。
    test('unterminated DCS is abandoned after the cap (single write)', () {
      final terminal = _makeTerminal();
      terminal.write('\x1bP0;0;8q${'#' * 70000}');
      terminal.write('after');
      expect(_screenText(terminal), contains('after'));
    });

    test('unterminated DCS is abandoned after the cap (chunked writes)', () {
      final terminal = _makeTerminal();
      terminal.write('\x1bP0;0;8q');
      terminal.write('#' * 35000);
      terminal.write('#' * 35000);
      terminal.write('after');
      expect(_screenText(terminal), contains('after'));
    });

    test('unterminated OSC is abandoned after the cap and not applied', () {
      final terminal = _makeTerminal();
      var title = '';
      terminal.onTitleChange = (t) => title = t;
      terminal.write('\x1b]0;${'x' * 70000}');
      terminal.write('after');
      expect(_screenText(terminal), contains('after'));
      expect(title, '', reason: 'capped OSC must be discarded, not applied');
    });

    test('unterminated CSI is abandoned after the cap', () {
      final terminal = _makeTerminal();
      terminal.write('\x1b[${';' * 70000}');
      terminal.write('after');
      expect(_screenText(terminal), contains('after'));
    });

    test('normal CSI sequences still work after the cap logic', () {
      final terminal = _makeTerminal();
      terminal.write('AB\x1b[1;1HZ');
      expect(_screenText(terminal), 'ZB');
    });
  });
}

Terminal _makeTerminal() {
  final terminal = Terminal(maxLines: 1000);
  terminal.resize(80, 24);
  return terminal;
}

/// 画面上の可視テキストを返す（行末空白と末尾の空行は除去）。
String _screenText(Terminal terminal) {
  final lines = <String>[];
  for (var i = 0; i < terminal.buffer.lines.length; i++) {
    lines.add(terminal.buffer.lines[i].toString().trimRight());
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}
