import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/char_metrics.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('calcCharSize', () {
    test('returns a positive width and height for the default style', () {
      final size = calcCharSize(const TerminalStyle(), TextScaler.noScaling);
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0));
    });

    test('width scales linearly with fontSize', () {
      final base = calcCharSize(
        const TerminalStyle(fontSize: 14),
        TextScaler.noScaling,
      );
      final doubled = calcCharSize(
        const TerminalStyle(fontSize: 28),
        TextScaler.noScaling,
      );

      // 2× fontSize -> 2× width and height (allow ±5% for rounding / hinting).
      expect(doubled.width / base.width, closeTo(2.0, 0.1));
      expect(doubled.height / base.height, closeTo(2.0, 0.1));
    });

    test('width scales linearly with textScaler', () {
      final base = calcCharSize(const TerminalStyle(), TextScaler.noScaling);
      final scaled = calcCharSize(
        const TerminalStyle(),
        const TextScaler.linear(2.0),
      );

      expect(scaled.width / base.width, closeTo(2.0, 0.1));
      expect(scaled.height / base.height, closeTo(2.0, 0.1));
    });

    test('height respects the style.height multiplier', () {
      final tight = calcCharSize(
        const TerminalStyle(height: 1.0),
        TextScaler.noScaling,
      );
      final tall = calcCharSize(
        const TerminalStyle(height: 2.0),
        TextScaler.noScaling,
      );
      expect(tall.height, greaterThan(tight.height));
    });

    test('two invocations with the same arguments return equal sizes', () {
      final a = calcCharSize(const TerminalStyle(), TextScaler.noScaling);
      final b = calcCharSize(const TerminalStyle(), TextScaler.noScaling);
      expect(a, equals(b));
    });
  });
}
