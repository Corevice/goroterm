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
}
