// Merged from: composition_buffer_test.dart, ime_input_handler_test.dart

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/features/terminal/ime/composition_buffer.dart';
import 'package:terminal_ssh_app/features/terminal/ime/ime_input_handler.dart';

void main() {
  // =====================================================================
  // composition_buffer.dart
  // =====================================================================
  group('CompositionBuffer', () {
    late CompositionBuffer buffer;

    setUp(() {
      buffer = CompositionBuffer();
    });

    group('state', () {
      test('initial state is not composing', () {
        expect(buffer.isComposing, isFalse);
        expect(buffer.composingText, isEmpty);
        expect(buffer.previousConfirmedText, isEmpty);
      });

      test('updateComposing sets composing state', () {
        buffer.updateComposing('かん');
        expect(buffer.isComposing, isTrue);
        expect(buffer.composingText, 'かん');
      });

      test('clearComposing resets composing state', () {
        buffer.updateComposing('かん');
        buffer.clearComposing();
        expect(buffer.isComposing, isFalse);
        expect(buffer.composingText, isEmpty);
      });

      test('reset clears all state', () {
        buffer.updateComposing('かん');
        buffer.updateConfirmedText('漢字');
        buffer.reset();
        expect(buffer.isComposing, isFalse);
        expect(buffer.composingText, isEmpty);
        expect(buffer.previousConfirmedText, isEmpty);
      });
    });

    group('extractDelta', () {
      test('empty previous returns full current', () {
        expect(CompositionBuffer.extractDelta('', 'hello'), 'hello');
      });

      test('current starts with previous returns suffix', () {
        expect(CompositionBuffer.extractDelta('hel', 'hello'), 'lo');
      });

      test('identical texts return empty', () {
        expect(CompositionBuffer.extractDelta('hello', 'hello'), '');
      });

      test('empty current returns empty', () {
        expect(CompositionBuffer.extractDelta('hello', ''), '');
      });

      test('completely different text returns full current', () {
        expect(CompositionBuffer.extractDelta('abc', 'xyz'), 'xyz');
      });

      test('predictive conversion (replacement) returns full text', () {
        expect(CompositionBuffer.extractDelta('abc', '漢字'), '漢字');
      });

      test('partial match with extension', () {
        expect(CompositionBuffer.extractDelta('abc', 'abcdef'), 'def');
      });

      test('Japanese text appending', () {
        expect(CompositionBuffer.extractDelta('東京', '東京都'), '都');
      });

      test('current shorter than previous returns full current text', () {
        expect(CompositionBuffer.extractDelta('abcdef', 'abc'), 'abc');
      });
    });

    group('isCancelled', () {
      test('empty text is cancelled', () {
        final value = const TextEditingValue(text: '');
        expect(CompositionBuffer.isCancelled(value, 'prev'), isTrue);
      });

      test('same as previous is cancelled', () {
        final value = const TextEditingValue(text: 'hello');
        expect(CompositionBuffer.isCancelled(value, 'hello'), isTrue);
      });

      test('different text is not cancelled', () {
        final value = const TextEditingValue(text: 'hello世界');
        expect(CompositionBuffer.isCancelled(value, 'hello'), isFalse);
      });
    });
  });

  // =====================================================================
  // ime_input_handler.dart
  // =====================================================================
  group('ImeInputHandler', () {
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
        handler.onTextInputAction(const TextEditingValue(
          text: 'か',
          composing: TextRange(start: 0, end: 1),
        ));
        expect(sentToSsh, isEmpty);
        expect(shownOverlays, ['か']);
        expect(handler.isComposing, isTrue);
      });

      test('sends confirmed text after composing ends', () {
        handler.onTextInputAction(const TextEditingValue(
          text: 'かん',
          composing: TextRange(start: 0, end: 2),
        ));
        expect(sentToSsh, isEmpty);

        handler.onTextInputAction(const TextEditingValue(text: '漢'));
        expect(sentToSsh, ['漢']);
        expect(clearOverlayCalls, 1);
      });

      test('does not send on cancel (Esc)', () {
        handler.onTextInputAction(const TextEditingValue(
          text: 'かん',
          composing: TextRange(start: 0, end: 2),
        ));
        handler.onTextInputAction(const TextEditingValue(text: ''));
        expect(sentToSsh, isEmpty);
        expect(clearOverlayCalls, 1);
      });

      test('does not send on cancel when text reverts to previous', () {
        handler.onTextInputAction(const TextEditingValue(text: 'abc'));
        sentToSsh.clear();

        handler.onTextInputAction(const TextEditingValue(
          text: 'abcかん',
          composing: TextRange(start: 3, end: 5),
        ));
        expect(sentToSsh, isEmpty);

        handler.onTextInputAction(const TextEditingValue(text: 'abc'));
        expect(sentToSsh, isEmpty);
      });

      test('consecutive confirmations do not duplicate', () {
        handler.onTextInputAction(const TextEditingValue(
          text: '東',
          composing: TextRange(start: 0, end: 1),
        ));
        handler.onTextInputAction(const TextEditingValue(text: '東'));
        expect(sentToSsh, ['東']);

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
        handler.onTextInputAction(const TextEditingValue(text: '𠮷'));
        expect(sentToSsh, ['𠮷']);
      });

      test('sends combining characters correctly', () {
        handler.onTextInputAction(const TextEditingValue(text: 'é'));
        expect(sentToSsh, ['é']);
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
  });
}
