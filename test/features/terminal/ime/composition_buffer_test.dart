import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/features/terminal/ime/composition_buffer.dart';

void main() {
  late CompositionBuffer buffer;

  setUp(() {
    buffer = CompositionBuffer();
  });

  group('CompositionBuffer state', () {
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
      // User typed "かんじ" (kanji) and prediction replaced with "漢字"
      expect(CompositionBuffer.extractDelta('abc', '漢字'), '漢字');
    });

    test('partial match with extension', () {
      expect(CompositionBuffer.extractDelta('abc', 'abcdef'), 'def');
    });

    test('Japanese text appending', () {
      expect(CompositionBuffer.extractDelta('東京', '東京都'), '都');
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
}
