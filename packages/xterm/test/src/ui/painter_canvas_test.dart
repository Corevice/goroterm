// TerminalPainter の paint 経路を recording canvas で検証する。
// `.color.value` は Flutter 3.27 で deprecated だが、Color の `==` が
// colorSpace 込みで厳密になるため int 比較に頼る必要がある。
// toARGB32() は SDK が古いと未提供なのでファイル単位で許容する。
// ignore_for_file: deprecated_member_use
//
// ゴールデン (terminal_view_test.dart) は !Platform.isMacOS で skip される
// ため、Linux CI で安定して走る検証が薄い。ここではフォーク独自の以下を pin:
//   - underline を TextDecoration ではなく Canvas.drawLine で描画
//   - paintCellBackground の幅が cellSize.width + 1
//   - cursor 形状切替 (block / underline / verticalBar / unfocused)
//   - inverse/normal の背景早期 return
//   - widthShift = 2 (CJK / 絵文字) で背景幅が 2 cell + 1
//
// Canvas を直接実装するのは flutter_test 標準では難しいので、
// 必要な 3 メソッド (drawRect / drawLine / drawParagraph) を記録する
// 最小限の Canvas プロキシを使う。
import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

class _DrawRectCall {
  _DrawRectCall(this.rect, this.color, this.style);
  final Rect rect;
  final Color color;
  final PaintingStyle style;
}

class _DrawLineCall {
  _DrawLineCall(this.p1, this.p2, this.color, this.strokeWidth);
  final Offset p1;
  final Offset p2;
  final Color color;
  final double strokeWidth;
}

class _DrawParagraphCall {
  _DrawParagraphCall(this.paragraph, this.offset);
  final Paragraph paragraph;
  final Offset offset;
}

class _RecordingCanvas implements Canvas {
  final List<_DrawRectCall> rects = [];
  final List<_DrawLineCall> lines = [];
  final List<_DrawParagraphCall> paragraphs = [];

  @override
  void drawRect(Rect rect, Paint paint) {
    rects.add(_DrawRectCall(rect, paint.color, paint.style));
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    lines.add(_DrawLineCall(p1, p2, paint.color, paint.strokeWidth));
  }

  @override
  void drawParagraph(Paragraph paragraph, Offset offset) {
    paragraphs.add(_DrawParagraphCall(paragraph, offset));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

TerminalPainter _makePainter() => TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

CellData _cell({
  int codepoint = 0,
  int widthShift = 1,
  int flags = 0,
  int foreground = CellColor.normal,
  int background = CellColor.normal,
}) {
  return CellData(
    foreground: foreground,
    background: background,
    flags: flags,
    content: codepoint | (widthShift << CellContent.widthShift),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalPainter.paintCellBackground', () {
    test('CellColor.normal background draws nothing', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellBackground(canvas, Offset.zero, _cell());
      expect(canvas.rects, isEmpty);
    });

    test('explicit rgb background draws one filled rect with cell+1 width', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellBackground(
        canvas,
        const Offset(10, 20),
        _cell(background: CellColor.rgb | 0xFF0000),
      );

      expect(canvas.rects, hasLength(1));
      final rect = canvas.rects.single;
      // Color の `==` は colorSpace 込みで厳密になるため value で比較する。
      expect(rect.color.value, 0xFFFF0000);
      expect(rect.rect.left, 10);
      expect(rect.rect.top, 20);
      // フォーク独自: +1 ピクセル幅で隣セルの境界を埋める。
      expect(rect.rect.width, painter.cellSize.width + 1);
      expect(rect.rect.height, painter.cellSize.height);
    });

    test('widthShift=2 (CJK / emoji) paints a 2× cell-width background', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellBackground(
        canvas,
        Offset.zero,
        _cell(
          widthShift: 2,
          background: CellColor.rgb | 0x00FF00,
        ),
      );

      expect(canvas.rects, hasLength(1));
      expect(canvas.rects.single.rect.width, painter.cellSize.width * 2 + 1);
    });

    test('inverse flag uses foreground color even when background is normal',
        () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellBackground(
        canvas,
        Offset.zero,
        _cell(
          flags: CellFlags.inverse,
          foreground: CellColor.rgb | 0xABCDEF,
        ),
      );

      expect(canvas.rects, hasLength(1));
      expect(canvas.rects.single.color.value, 0xFFABCDEF);
    });
  });

  group('TerminalPainter.paintCellForeground', () {
    test('empty cell (codepoint=0) without underline draws nothing', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellForeground(canvas, Offset.zero, _cell());
      expect(canvas.paragraphs, isEmpty);
      expect(canvas.lines, isEmpty);
    });

    test('printable cell draws exactly one paragraph at the cell offset', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellForeground(
        canvas,
        const Offset(5, 7),
        _cell(codepoint: 'A'.codeUnitAt(0)),
      );
      expect(canvas.paragraphs, hasLength(1));
      expect(canvas.paragraphs.single.offset, const Offset(5, 7));
      expect(canvas.lines, isEmpty,
          reason: 'no underline flag -> no Canvas drawLine');
    });

    test('underline flag draws a drawLine spanning one cell width', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellForeground(
        canvas,
        const Offset(0, 0),
        _cell(codepoint: 'A'.codeUnitAt(0), flags: CellFlags.underline),
      );
      expect(canvas.lines, hasLength(1));
      final line = canvas.lines.single;
      expect(line.p1.dx, 0);
      expect(line.p2.dx, painter.cellSize.width);
      // y is bottom-1 of the cell.
      expect(line.p1.dy, painter.cellSize.height - 1);
      expect(line.p2.dy, painter.cellSize.height - 1);
    });

    test('underline + widthShift=2 stretches the line across 2 cells', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellForeground(
        canvas,
        Offset.zero,
        _cell(
          codepoint: 0x3042, // ひらがな 'あ'
          widthShift: 2,
          flags: CellFlags.underline,
        ),
      );
      expect(canvas.lines, hasLength(1));
      expect(canvas.lines.single.p2.dx, painter.cellSize.width * 2);
    });

    test('underline on empty cell (codepoint=0) still draws the line', () {
      // 罫線・連続下線で空セルにも下線が来るケースをカバー。
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCellForeground(
        canvas,
        Offset.zero,
        _cell(flags: CellFlags.underline),
      );
      expect(canvas.lines, hasLength(1));
      expect(canvas.paragraphs, isEmpty);
    });

    test('paragraph is reused from cache on identical cells', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      final cell = _cell(codepoint: 'A'.codeUnitAt(0));
      painter.paintCellForeground(canvas, Offset.zero, cell);
      painter.paintCellForeground(canvas, const Offset(20, 0), cell);

      expect(canvas.paragraphs, hasLength(2));
      // 2 回目は cache hit で同じ Paragraph オブジェクトが使われる。
      expect(
        identical(canvas.paragraphs[0].paragraph, canvas.paragraphs[1].paragraph),
        isTrue,
      );
    });
  });

  group('TerminalPainter.paintCursor', () {
    test('block cursor draws a filled rect over the cell', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCursor(
        canvas,
        Offset.zero,
        cursorType: TerminalCursorType.block,
      );
      expect(canvas.rects, hasLength(1));
      expect(canvas.rects.single.style, PaintingStyle.fill);
      expect(canvas.lines, isEmpty);
    });

    test('underline cursor draws a horizontal line at the cell bottom', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCursor(
        canvas,
        Offset.zero,
        cursorType: TerminalCursorType.underline,
      );
      expect(canvas.lines, hasLength(1));
      final l = canvas.lines.single;
      expect(l.p1.dy, painter.cellSize.height - 1);
      expect(l.p2.dy, painter.cellSize.height - 1);
      expect(l.p1.dx, 0);
      expect(l.p2.dx, painter.cellSize.width);
      expect(canvas.rects, isEmpty);
    });

    test('verticalBar cursor draws a vertical line at the cell left edge', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCursor(
        canvas,
        Offset.zero,
        cursorType: TerminalCursorType.verticalBar,
      );
      expect(canvas.lines, hasLength(1));
      final l = canvas.lines.single;
      expect(l.p1.dx, 0);
      expect(l.p2.dx, 0);
      expect(l.p2.dy, painter.cellSize.height);
      expect(canvas.rects, isEmpty);
    });

    test('unfocused cursor draws a stroked rect regardless of cursorType', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintCursor(
        canvas,
        Offset.zero,
        cursorType: TerminalCursorType.block,
        hasFocus: false,
      );
      expect(canvas.rects, hasLength(1));
      expect(canvas.rects.single.style, PaintingStyle.stroke);
    });
  });

  group('TerminalPainter.paintHighlight', () {
    test('draws one rect spanning length cells with the given color', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      painter.paintHighlight(
        canvas,
        const Offset(4, 8),
        3,
        const Color(0x80FF0000),
      );
      expect(canvas.rects, hasLength(1));
      final r = canvas.rects.single;
      expect(r.color.value, 0x80FF0000);
      expect(r.rect.left, 4);
      expect(r.rect.top, 8);
      expect(r.rect.width, painter.cellSize.width * 3);
      expect(r.rect.height, painter.cellSize.height);
    });
  });

  group('TerminalPainter.textStyle setter', () {
    test('changing textStyle clears the paragraph cache', () {
      final painter = _makePainter();
      final canvas = _RecordingCanvas();
      final cell = _cell(codepoint: 'A'.codeUnitAt(0));

      painter.paintCellForeground(canvas, Offset.zero, cell);
      final firstParagraph = canvas.paragraphs.single.paragraph;

      painter.textStyle = const TerminalStyle(fontSize: 28);
      painter.paintCellForeground(canvas, const Offset(0, 30), cell);
      final secondParagraph = canvas.paragraphs.last.paragraph;

      expect(identical(firstParagraph, secondParagraph), isFalse,
          reason: 'cache must be invalidated after textStyle change');
    });
  });
}
