import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/features/terminal/ime/ime_input_handler.dart';

void main() {
  late ImeInputHandler handler;
  late List<String> sentToSsh;
  late List<String> shownOverlays;
  late int clearOverlayCalls;

  setUp(() {
    sentToSsh = [];
    shownOverlays = [];
    clearOverlayCalls = 0;
    handler = ImeInputHandler(
      onSendToSsh: (text) => sentToSsh.add(text),
      onShowComposingOverlay: (text) => shownOverlays.add(text),
      onClearComposingOverlay: () => clearOverlayCalls++,
    );
  });

  group('Normal ASCII input', () {
    test('sends delta for new text', () {
      handler.onTextInputAction(const TextEditingValue(text: 'a'));
      expect(sentToSsh, ['a']);

      handler.onTextInputAction(const TextEditingValue(text: 'ab'));
      expect(sentToSsh, ['a', 'b']);
    });

    test('does not send when text unchanged', () {
      handler.onTextInputAction(const TextEditingValue(text: 'a'));
      handler.onTextInputAction(const TextEditingValue(text: 'a'));
      expect(sentToSsh, ['a']);
    });
  });

  group('Japanese IME composing', () {
    test('shows overlay during composing and does not send to SSH', () {
      // User types "か" (composing)
      handler.onTextInputAction(const TextEditingValue(
        text: 'か',
        composing: TextRange(start: 0, end: 1),
      ));
      expect(sentToSsh, isEmpty);
      expect(shownOverlays, ['か']);
      expect(handler.isComposing, isTrue);
    });

    test('sends confirmed text after composing ends', () {
      // Composing "かん"
      handler.onTextInputAction(const TextEditingValue(
        text: 'かん',
        composing: TextRange(start: 0, end: 2),
      ));
      expect(sentToSsh, isEmpty);

      // Confirmed "漢"
      handler.onTextInputAction(const TextEditingValue(text: '漢'));
      expect(sentToSsh, ['漢']);
      expect(clearOverlayCalls, 1);
    });

    test('does not send on cancel (Esc)', () {
      // Composing "かん"
      handler.onTextInputAction(const TextEditingValue(
        text: 'かん',
        composing: TextRange(start: 0, end: 2),
      ));

      // Cancelled (text becomes empty)
      handler.onTextInputAction(const TextEditingValue(text: ''));
      expect(sentToSsh, isEmpty);
      expect(clearOverlayCalls, 1);
    });

    test('does not send on cancel when text reverts to previous', () {
      // First, send "abc"
      handler.onTextInputAction(const TextEditingValue(text: 'abc'));
      sentToSsh.clear();

      // Start composing
      handler.onTextInputAction(const TextEditingValue(
        text: 'abcかん',
        composing: TextRange(start: 3, end: 5),
      ));
      expect(sentToSsh, isEmpty);

      // Cancel: text reverts to "abc" (same as previous confirmed)
      handler.onTextInputAction(const TextEditingValue(text: 'abc'));
      expect(sentToSsh, isEmpty);
    });

    test('consecutive confirmations do not duplicate', () {
      // First confirmation
      handler.onTextInputAction(const TextEditingValue(
        text: '東',
        composing: TextRange(start: 0, end: 1),
      ));
      handler.onTextInputAction(const TextEditingValue(text: '東'));
      expect(sentToSsh, ['東']);

      // Second confirmation
      handler.onTextInputAction(const TextEditingValue(
        text: '東京',
        composing: TextRange(start: 1, end: 2),
      ));
      handler.onTextInputAction(const TextEditingValue(text: '東京'));
      expect(sentToSsh, ['東', '京']);
    });
  });

  group('Enter key', () {
    test('sends \\r when not composing', () {
      handler.onEnterKey();
      expect(sentToSsh, ['\r']);
    });

    test('does not send \\r during composing', () {
      handler.onTextInputAction(const TextEditingValue(
        text: 'かん',
        composing: TextRange(start: 0, end: 2),
      ));
      handler.onEnterKey();
      expect(sentToSsh, isEmpty);
    });
  });

  group('Paste', () {
    test('sends sanitized text directly', () {
      handler.onPaste('hello\nworld');
      expect(sentToSsh, ['hello\rworld']);
    });

    test('handles Windows line endings', () {
      handler.onPaste('line1\r\nline2');
      expect(sentToSsh, ['line1\rline2']);
    });
  });

  group('Emoji and surrogate pairs', () {
    test('sends emoji directly as normal input', () {
      handler.onTextInputAction(const TextEditingValue(text: '😀'));
      expect(sentToSsh, ['😀']);
    });

    test('sends CJK supplementary character (surrogate pair)', () {
      // 𠮷 is U+20BB7, encoded as surrogate pair in UTF-16
      handler.onTextInputAction(const TextEditingValue(text: '𠮷'));
      expect(sentToSsh, ['𠮷']);
    });

    test('sends combining characters correctly', () {
      // é as base + combining accent (U+0065 U+0301)
      handler.onTextInputAction(const TextEditingValue(text: 'e\u0301'));
      expect(sentToSsh, ['e\u0301']);
    });

    test('paste preserves emoji', () {
      handler.onPaste('hello 😀 world');
      expect(sentToSsh, ['hello 😀 world']);
    });

    test('paste preserves CJK supplementary characters', () {
      handler.onPaste('test 𠮷 end');
      expect(sentToSsh, ['test 𠮷 end']);
    });

    test('consecutive emoji inputs send correct deltas', () {
      handler.onTextInputAction(const TextEditingValue(text: '😀'));
      handler.onTextInputAction(const TextEditingValue(text: '😀😂'));
      expect(sentToSsh, ['😀', '😂']);
    });
  });

  group('Reset', () {
    test('clears all state', () {
      handler.onTextInputAction(const TextEditingValue(
        text: 'かん',
        composing: TextRange(start: 0, end: 2),
      ));
      handler.reset();
      expect(handler.isComposing, isFalse);
      expect(handler.composingText, isEmpty);
      expect(clearOverlayCalls, 1);
    });
  });
}
