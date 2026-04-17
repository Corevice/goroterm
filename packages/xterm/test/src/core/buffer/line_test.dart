import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

/// Builds a [BufferLine] where each cell's codePoint is [base] + index.
/// Default base is 65 ('A'), so a 5-cell line contains A B C D E.
BufferLine _makeLineForTest(int length, {int base = 65}) {
  final line = BufferLine(length);
  for (var i = 0; i < length; i++) {
    line.setCodePoint(i, base + i);
  }
  return line;
}

void main() {
  group('BufferLine.getText()', () {
    test('should return the text', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(), 'Hello World');
    });

    test('getText() should support wide characters', () {
      final text = '😀😁😂🤣😃';
      final terminal = Terminal();
      terminal.write(text);
      expect(terminal.buffer.lines[0].getText(), equals(text));
    });

    test('can specify a range', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(0, 5), 'Hello');
    });

    test('can handle invalid ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(0, 100), 'Hello World');
    });

    test('can handle negative ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(-100, 100), 'Hello World');
    });

    test('can handle reversed ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(5, 0), '');
    });

    // The second cell of a wide character (emoji/CJK) has codePoint == 0 but
    // must NOT be emitted as a space.  Without this guard, adjacent wide chars
    // like "😀😁" would become "😀 😁" with a spurious space in between.
    test('wide character continuation cells do not produce extra spaces', () {
      final terminal = Terminal();
      terminal.write('😀😁'); // two adjacent wide chars
      // getText() must return the two emoji without any space between them.
      expect(terminal.buffer.lines[0].getText(), '😀😁',
          reason: 'continuation cells of wide chars must not produce spaces');
    });

    // Empty cells (code point == 0) are rendered as spaces so that
    // column-aligned output (tables, indentation) is preserved on copy.
    test('empty cells between text are represented as spaces', () {
      // BufferLine(10) starts with all cells empty (codePoint == 0).
      // Write 'A','B' at columns 0-1, leave columns 2-3 empty, write 'C','D' at 4-5.
      final line = BufferLine(10);
      line.setCodePoint(0, 'A'.codeUnitAt(0));
      line.setCodePoint(1, 'B'.codeUnitAt(0));
      // columns 2 and 3 intentionally left as codePoint == 0 (empty)
      line.setCodePoint(4, 'C'.codeUnitAt(0));
      line.setCodePoint(5, 'D'.codeUnitAt(0));
      // Expected: "AB  CD" — two spaces for the two empty cells; columns 6-9
      // are also empty but they are trailing so they get trimmed.
      expect(line.getText(0, 6), 'AB  CD');
    });

    // Terminal lines are always padded to viewWidth with empty cells (code
    // point == 0).  getText() must trim trailing spaces so that URL detection
    // and copy-paste do not accumulate spurious whitespace at the end.
    test('trailing empty cells are trimmed from the result', () {
      final terminal = Terminal();
      terminal.write('Hello'); // rest of the 80-column line is empty cells
      // getText() with no range spans the full line width.
      final text = terminal.buffer.lines[0].getText();
      expect(text, 'Hello',
          reason: 'trailing empty-cell spaces must be trimmed');
      expect(text.endsWith(' '), isFalse,
          reason: 'result must not end with a space');
    });

    // A line that contains only empty cells (never written to) should return
    // an empty string after trimRight, not a string of spaces.
    test('all-empty line returns empty string', () {
      final line = BufferLine(10); // all code points == 0
      expect(line.getText(), '',
          reason: 'an all-empty line must produce an empty string');
    });

    // When a range is specified that ends inside written text, trailing-space
    // trimming must still apply to what falls inside the range.
    test('getText() with range trims trailing empty cells within range', () {
      final line = BufferLine(10);
      line.setCodePoint(0, 'H'.codeUnitAt(0));
      line.setCodePoint(1, 'i'.codeUnitAt(0));
      // columns 2-9 are empty
      // getText(0, 6) covers "Hi" + 4 empty → must return "Hi" after trim
      expect(line.getText(0, 6), 'Hi');
    });

    // The implementation distinguishes actual space characters (codePoint == 0x20)
    // from empty cells (codePoint == 0).  Actual spaces are written to the output
    // directly and are never trimmed, while empty cells at the end of the range
    // are silently dropped.  This matters for wrapped lines: the terminal writes a
    // real 0x20 at the last column of a soft-wrapped line to signal continuation.
    // Trimming that space would concatenate the two visual lines on copy-paste.
    test('trailing actual space characters (0x20) are preserved, unlike trailing empty cells', () {
      final line = BufferLine(10);
      line.setCodePoint(0, 'H'.codeUnitAt(0));
      line.setCodePoint(1, 'i'.codeUnitAt(0));
      line.setCodePoint(2, 0x20); // actual space
      line.setCodePoint(3, 0x20); // actual space
      // columns 4-9 are empty cells (codePoint == 0) — these must be trimmed
      expect(
        line.getText(),
        'Hi  ',
        reason: 'actual 0x20 spaces must not be trimmed; '
            'only empty cells (0x00) are dropped at the end',
      );
    });

    // When actual spaces (0x20) are followed by empty cells, the empty cells
    // must be trimmed while the spaces are preserved.  This is the key wrapped-
    // line scenario: the terminal writes text + one real space + empty padding.
    test('actual spaces followed by empty cells: spaces kept, empty cells dropped', () {
      final line = BufferLine(8);
      line.setCodePoint(0, 'A'.codeUnitAt(0));
      line.setCodePoint(1, 'B'.codeUnitAt(0));
      line.setCodePoint(2, 0x20); // real trailing space (soft-wrap marker)
      // cols 3-7 are empty (codePoint == 0)
      expect(
        line.getText(),
        'AB ',
        reason: 'the trailing real space must survive; empty padding is dropped',
      );
    });

    // A wide character (e.g. an emoji) occupies two cells.  When a range is
    // specified and the wide character's right cell would fall outside the
    // range, the entire character must be excluded from the output.
    // The condition `i + width <= to` in getText() enforces this.
    //
    // Without this guard, `builder.writeCharCode(codePoint)` would emit a
    // character whose second cell is outside the requested range — producing
    // visually incorrect copy-paste output (missing glyph or wrong alignment).
    test('wide character that overflows range boundary is excluded', () {
      final terminal = Terminal();
      terminal.write('AB😀'); // A→col 0, B→col 1, 😀→cols 2-3 (width=2)
      final line = terminal.buffer.lines[0];

      // getText(0, 3): range ends before col 3, so 😀 (cols 2-3) overflows.
      // i=2, width=2 → i+width=4 > 3 → wide char excluded.
      expect(
        line.getText(0, 3),
        'AB',
        reason: 'wide char overflowing the range boundary must be excluded '
            'to avoid partial-character artefacts in copy-paste output',
      );
    });

    // Counterpart: when the range is wide enough to accommodate both cells of
    // a wide character, it must appear in the output.
    test('wide character is included when both cells fit within range', () {
      final terminal = Terminal();
      terminal.write('AB😀'); // A→col 0, B→col 1, 😀→cols 2-3 (width=2)
      final line = terminal.buffer.lines[0];

      // getText(0, 4): range ends at col 4, so 😀 (cols 2-3) fits.
      // i=2, width=2 → i+width=4 <= 4 → wide char included.
      expect(
        line.getText(0, 4),
        'AB😀',
        reason: 'wide char must be included when both cells are within the range',
      );
    });

    // A wide character that starts exactly at 'from' and whose right cell fits
    // within the range must be included.  This tests the general case where the
    // range does not start at column 0.
    test('wide character starting at from boundary is included when it fits', () {
      final terminal = Terminal();
      terminal.write('AB😀C'); // A→0, B→1, 😀→2-3, C→4
      final line = terminal.buffer.lines[0];

      // getText(2, 5): starts at the 😀 (col 2) — both its cells (2-3) are in
      // [2, 5), and C at col 4 also fits.
      expect(
        line.getText(2, 5),
        '😀C',
        reason: 'wide char at from boundary must be included when both cells fit',
      );
    });

    // The isPrevWide guard in getText() checks whether a zero-codePoint cell is
    // the right (continuation) half of a wide character.  When 'from' itself
    // points to that continuation cell the guard must still fire — even though
    // the left half is outside the requested range — so no spurious space is
    // emitted at the start of the result.
    //
    // Without the `i > 0 && getWidth(i - 1) == 2` check the continuation cell
    // would be treated as an empty cell and counted as a pending space, which
    // would appear as a leading space before the next real character.
    test('range starting at continuation cell does not emit a spurious space', () {
      final terminal = Terminal();
      terminal.write('😀C'); // 😀→cols 0-1 (width 2), C→col 2
      final line = terminal.buffer.lines[0];

      // getText(1, 3): col 1 is the right (continuation) cell of 😀.
      // The result should be just "C" — no leading space.
      expect(
        line.getText(1, 3),
        'C',
        reason: 'continuation cell at from must not produce a spurious leading space',
      );
    });

    // Closely related: when the range starts at the continuation cell AND there
    // are further empty cells before the next real character, those empty cells
    // must still be counted as pending spaces (they are real gaps, not
    // continuation cells).
    test('empty cells after continuation cell are counted as spaces', () {
      final terminal = Terminal();
      terminal.write('😀'); // 😀→cols 0-1; rest of line is empty
      final line = terminal.buffer.lines[0];
      // Manually place 'Z' at col 4, leaving cols 2-3 empty (codePoint == 0).
      line.setCodePoint(4, 'Z'.codeUnitAt(0));

      // getText(1, 5): col 1 = continuation cell (skip, no space),
      //               cols 2-3 = empty cells (→ 2 pending spaces),
      //               col 4 = 'Z' (flush spaces → "  Z").
      expect(
        line.getText(1, 5),
        '  Z',
        reason: 'empty cells after a continuation cell must still produce spaces',
      );
    });
  });

  group('BufferLine.getTrimmedLength()', () {
    test('can get trimmed length', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(), equals(text.length));
    });

    test('can get trimmed length with wide characters', () {
      final terminal = Terminal();
      final text = '😀😁😂🤣😃';

      terminal.write(text);

      expect(terminal.buffer.lines[0].getTrimmedLength(), equals(text.length));
    });

    test('can handle length larger than the line', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(1000), equals(text.length));
    });

    test('can handle negative start', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(-1000), equals(0));
    });
  });

  group('BufferLine.resize', () {
    test('can resize', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      line.resize(20);

      expect(line.length, equals(20));
    });
  });

  group('BufferLine.copyFrom()', () {
    test('copies all cells from srcCol=0 to dstCol=0', () {
      final src = _makeLineForTest(5); // A B C D E
      final dst = BufferLine(5);
      dst.copyFrom(src, 0, 0, 5);
      for (var i = 0; i < 5; i++) {
        expect(dst.getCodePoint(i), src.getCodePoint(i),
            reason: 'cell $i must match source');
      }
    });

    test('copies a subset of source cells (srcCol > 0)', () {
      final src = _makeLineForTest(5); // A B C D E  (code points 65..69)
      final dst = BufferLine(3);
      // Copy cells 2..4 from src ('C' 'D' 'E') to dst at col 0.
      dst.copyFrom(src, 2, 0, 3);
      expect(dst.getCodePoint(0), 67); // 'C'
      expect(dst.getCodePoint(1), 68); // 'D'
      expect(dst.getCodePoint(2), 69); // 'E'
    });

    test('copies to a non-zero dstCol', () {
      final src = _makeLineForTest(3); // A B C
      final dst = BufferLine(6);
      // Leave cols 0-2 empty, copy src starting at dst col 3.
      dst.copyFrom(src, 0, 3, 3);
      // Cols 0-2 must remain at code point 0 (empty).
      for (var i = 0; i < 3; i++) {
        expect(dst.getCodePoint(i), 0, reason: 'col $i must remain empty');
      }
      expect(dst.getCodePoint(3), 65); // 'A'
      expect(dst.getCodePoint(4), 66); // 'B'
      expect(dst.getCodePoint(5), 67); // 'C'
    });

    test('copyFrom with srcCol > 0 and dstCol > 0', () {
      final src = _makeLineForTest(6); // A B C D E F  (65..70)
      final dst = BufferLine(8);
      // Copy src cells 1..3 ('B','C','D') to dst cols 2..4.
      dst.copyFrom(src, 1, 2, 3);
      expect(dst.getCodePoint(2), 66); // 'B'
      expect(dst.getCodePoint(3), 67); // 'C'
      expect(dst.getCodePoint(4), 68); // 'D'
    });

    test('copies cell attributes (foreground, background, flags)', () {
      final src = BufferLine(2);
      // Manually set raw data so we can verify non-codepoint fields are copied.
      src.setForeground(0, 0xAABBCC);
      src.setBackground(0, 0x112233);
      src.setAttributes(0, 0xFF);
      src.setCodePoint(0, 65); // 'A'

      final dst = BufferLine(2);
      dst.copyFrom(src, 0, 0, 1);

      expect(dst.getForeground(0), 0xAABBCC);
      expect(dst.getBackground(0), 0x112233);
      expect(dst.getAttributes(0), 0xFF);
      expect(dst.getCodePoint(0), 65);
    });

    test('dst is resized when dstCol + len exceeds current length', () {
      final src = _makeLineForTest(3);
      final dst = BufferLine(1); // only 1 cell initially
      // Writing 3 cells at col 0 requires resize to at least 3.
      dst.copyFrom(src, 0, 0, 3);
      expect(dst.length, greaterThanOrEqualTo(3));
      expect(dst.getCodePoint(0), 65);
      expect(dst.getCodePoint(1), 66);
      expect(dst.getCodePoint(2), 67);
    });
  });

  group('BufferLine.createCellData()', () {
    test('returns cell data matching what was written', () {
      final line = BufferLine(3);
      line.setForeground(1, 0xFF0000);
      line.setBackground(1, 0x00FF00);
      line.setAttributes(1, 0x42);
      line.setCodePoint(1, 'Z'.codeUnitAt(0));

      final cell = line.createCellData(1);

      expect(cell.foreground, 0xFF0000);
      expect(cell.background, 0x00FF00);
      expect(cell.flags, 0x42);
      expect(cell.content & 0x1FFFFF, 'Z'.codeUnitAt(0));
    });

    test('does not corrupt the buffer cell when called', () {
      final line = BufferLine(2);
      line.setForeground(0, 0xABCDEF);
      line.setBackground(0, 0x123456);
      line.setCodePoint(0, 65); // 'A'

      line.createCellData(0); // must only read, not write

      expect(line.getForeground(0), 0xABCDEF,
          reason: 'createCellData must not overwrite foreground');
      expect(line.getBackground(0), 0x123456,
          reason: 'createCellData must not overwrite background');
      expect(line.getCodePoint(0), 65,
          reason: 'createCellData must not overwrite codePoint');
    });
  });

  group('Buffer.createAnchor', () {
    test('works', () {
      final terminal = Terminal();
      final line = terminal.buffer.lines[3];
      final anchor = line.createAnchor(5);

      terminal.insertLines(5);
      expect(anchor.x, 5);
      expect(anchor.y, 8);

      terminal.buffer.clear();
      expect(line.attached, false);
      expect(anchor.attached, false);
    });
  });
}
