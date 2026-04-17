import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

/// Creates a [TerminalPainter] with the default theme for use in unit tests.
TerminalPainter _makePainter() {
  return TerminalPainter(
    theme: TerminalThemes.defaultTheme,
    textStyle: const TerminalStyle(),
    textScaler: TextScaler.noScaling,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // resolveForegroundColor()
  // ---------------------------------------------------------------------------
  group('TerminalPainter.resolveForegroundColor()', () {
    late TerminalPainter painter;

    setUp(() => painter = _makePainter());

    test('CellColor.normal returns theme.foreground', () {
      expect(
        painter.resolveForegroundColor(CellColor.normal),
        TerminalThemes.defaultTheme.foreground,
      );
    });

    test('CellColor.rgb encodes red (0xFF0000) with full opacity', () {
      final cellColor = CellColor.rgb | 0xFF0000;
      expect(
        painter.resolveForegroundColor(cellColor),
        const Color(0xFFFF0000),
      );
    });

    test('CellColor.rgb encodes green (0x00FF00) with full opacity', () {
      final cellColor = CellColor.rgb | 0x00FF00;
      expect(
        painter.resolveForegroundColor(cellColor),
        const Color(0xFF00FF00),
      );
    });

    test('CellColor.rgb encodes blue (0x0000FF) with full opacity', () {
      final cellColor = CellColor.rgb | 0x0000FF;
      expect(
        painter.resolveForegroundColor(cellColor),
        const Color(0xFF0000FF),
      );
    });

    test('CellColor.rgb black (0x000000) returns opaque black', () {
      final cellColor = CellColor.rgb | 0x000000;
      expect(
        painter.resolveForegroundColor(cellColor),
        const Color(0xFF000000),
      );
    });

    test('CellColor.rgb white (0xFFFFFF) returns opaque white', () {
      final cellColor = CellColor.rgb | 0xFFFFFF;
      expect(
        painter.resolveForegroundColor(cellColor),
        const Color(0xFFFFFFFF),
      );
    });

    test('CellColor.named index 0 returns a Color (from palette)', () {
      final cellColor = CellColor.named | 0;
      expect(painter.resolveForegroundColor(cellColor), isA<Color>());
    });

    test('CellColor.palette index 0 returns a Color (from palette)', () {
      final cellColor = CellColor.palette | 0;
      expect(painter.resolveForegroundColor(cellColor), isA<Color>());
    });

    // named and palette share the same _colorPalette lookup table.
    test('CellColor.named and CellColor.palette with same index return same Color', () {
      const index = 5;
      final named = painter.resolveForegroundColor(CellColor.named | index);
      final palette = painter.resolveForegroundColor(CellColor.palette | index);
      expect(named, equals(palette));
    });
  });

  // ---------------------------------------------------------------------------
  // resolveBackgroundColor()
  // ---------------------------------------------------------------------------
  group('TerminalPainter.resolveBackgroundColor()', () {
    late TerminalPainter painter;

    setUp(() => painter = _makePainter());

    test('CellColor.normal returns theme.background', () {
      expect(
        painter.resolveBackgroundColor(CellColor.normal),
        TerminalThemes.defaultTheme.background,
      );
    });

    test('CellColor.rgb encodes blue (0x0000FF) with full opacity', () {
      final cellColor = CellColor.rgb | 0x0000FF;
      expect(
        painter.resolveBackgroundColor(cellColor),
        const Color(0xFF0000FF),
      );
    });

    test('CellColor.rgb white (0xFFFFFF) returns opaque white', () {
      final cellColor = CellColor.rgb | 0xFFFFFF;
      expect(
        painter.resolveBackgroundColor(cellColor),
        const Color(0xFFFFFFFF),
      );
    });

    test('CellColor.named index 0 returns a Color (from palette)', () {
      final cellColor = CellColor.named | 0;
      expect(painter.resolveBackgroundColor(cellColor), isA<Color>());
    });

    // foreground and background resolve the same palette for named/palette types.
    test('CellColor.named same index gives same Color for fg and bg', () {
      const index = 3;
      final fg = painter.resolveForegroundColor(CellColor.named | index);
      final bg = painter.resolveBackgroundColor(CellColor.named | index);
      expect(fg, equals(bg));
    });
  });

  // ---------------------------------------------------------------------------
  // TerminalPainter.cellSize
  // ---------------------------------------------------------------------------
  group('TerminalPainter.cellSize', () {
    test('returns a non-zero width and height', () {
      final painter = _makePainter();
      expect(painter.cellSize.width, greaterThan(0),
          reason: 'cell width must be positive');
      expect(painter.cellSize.height, greaterThan(0),
          reason: 'cell height must be positive');
    });
  });

  // ---------------------------------------------------------------------------
  // TerminalPainter setter: textScaler
  // ---------------------------------------------------------------------------
  group('TerminalPainter.textScaler setter', () {
    test('changing textScaler increases cellSize proportionally', () {
      final painter = _makePainter(); // noScaling (factor 1.0)
      final original = painter.cellSize;

      painter.textScaler = const TextScaler.linear(2.0);
      final scaled = painter.cellSize;

      expect(scaled.width, greaterThan(original.width),
          reason: '2× scale must produce a wider cell');
      expect(scaled.height, greaterThan(original.height),
          reason: '2× scale must produce a taller cell');
    });

    test('setting textScaler to the same value does not change cellSize', () {
      final painter = _makePainter();
      final before = painter.cellSize;

      painter.textScaler = TextScaler.noScaling; // same as initial
      final after = painter.cellSize;

      expect(after, equals(before));
    });
  });

  // ---------------------------------------------------------------------------
  // TerminalPainter setter: textStyle
  // ---------------------------------------------------------------------------
  group('TerminalPainter.textStyle setter', () {
    test('increasing fontSize enlarges cellSize', () {
      final painter = _makePainter(); // default fontSize = 14
      final original = painter.cellSize;

      painter.textStyle = const TerminalStyle(fontSize: 28.0); // 2× size
      final larger = painter.cellSize;

      expect(larger.width, greaterThan(original.width),
          reason: 'larger font must produce a wider cell');
      expect(larger.height, greaterThan(original.height),
          reason: 'larger font must produce a taller cell');
    });

    test('setting textStyle to the same value does not change cellSize', () {
      final painter = _makePainter();
      final before = painter.cellSize;

      painter.textStyle = const TerminalStyle(); // same as initial
      final after = painter.cellSize;

      expect(after, equals(before));
    });
  });

  // ---------------------------------------------------------------------------
  // TerminalPainter setter: theme
  // ---------------------------------------------------------------------------
  group('TerminalPainter.theme setter', () {
    test('changing theme updates foreground resolution', () {
      final painter = _makePainter();
      const originalFg = Color(0xFFCCCCCC); // defaultTheme.foreground
      expect(painter.resolveForegroundColor(CellColor.normal), originalFg);

      // Create a custom theme with a distinct foreground.
      const customFg = Color(0xFF00FF00);
      final customTheme = TerminalTheme(
        cursor: const Color(0xFFFFFFFF),
        selection: const Color(0xFFFFFFFF),
        foreground: customFg,
        background: const Color(0xFF000000),
        black: const Color(0xFF000000),
        red: const Color(0xFFFF0000),
        green: const Color(0xFF00FF00),
        yellow: const Color(0xFFFFFF00),
        blue: const Color(0xFF0000FF),
        magenta: const Color(0xFFFF00FF),
        cyan: const Color(0xFF00FFFF),
        white: const Color(0xFFFFFFFF),
        brightBlack: const Color(0xFF555555),
        brightRed: const Color(0xFFFF5555),
        brightGreen: const Color(0xFF55FF55),
        brightYellow: const Color(0xFFFFFF55),
        brightBlue: const Color(0xFF5555FF),
        brightMagenta: const Color(0xFFFF55FF),
        brightCyan: const Color(0xFF55FFFF),
        brightWhite: const Color(0xFFFFFFFF),
        searchHitBackground: const Color(0xFFFFFF00),
        searchHitBackgroundCurrent: const Color(0xFFFF8C00),
        searchHitForeground: const Color(0xFF000000),
      );

      painter.theme = customTheme;
      expect(painter.resolveForegroundColor(CellColor.normal), customFg);
    });

    test('setting theme to same value does not change resolution', () {
      final painter = _makePainter();
      final before = painter.resolveForegroundColor(CellColor.normal);
      painter.theme = TerminalThemes.defaultTheme;
      final after = painter.resolveForegroundColor(CellColor.normal);
      expect(after, equals(before));
    });
  });
}
