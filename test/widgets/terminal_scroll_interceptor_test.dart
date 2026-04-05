import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:terminal_ssh_app/widgets/terminal_scroll_interceptor.dart';

void main() {
  group('TerminalScrollInterceptor', () {
    late Terminal terminal;

    setUp(() {
      terminal = Terminal(maxLines: 100);
    });

    testWidgets('renders child widget', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalScrollInterceptor(
            terminal: terminal,
            child: const SizedBox(width: 300, height: 400),
          ),
        ),
      );

      expect(find.byType(TerminalScrollInterceptor), findsOneWidget);
      expect(find.byType(SizedBox), findsOneWidget);
    });

    testWidgets('does not intercept when not in alt buffer', (tester) async {
      // terminal は初期状態で main buffer
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: terminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // タッチジェスチャを実行しても alt buffer でないのでインターセプトしない
      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      await gesture.moveBy(const Offset(0, -100));
      await gesture.up();
      await tester.pump();

      // エラーなく完了すれば OK
    });

    testWidgets('does not intercept mouse events even in alt buffer', (tester) async {
      // alt buffer に切り替え
      terminal.write('\x1B[?1049h');

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: terminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // マウスイベントは無視される
      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(0, -100));
      await gesture.up();
      await tester.pump();

      // エラーなく完了すれば OK
    });

    testWidgets('intercepts vertical touch in alt buffer', (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h'); // alt buffer に切り替え
      testTerminal.write('\x1B[?1000h'); // X11 mouse mode on

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // 垂直スワイプを実行（GestureDetector が認識できるよう tester.drag を使用）
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, -80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // mouseInput または keyInput が呼ばれてエスケープシーケンスが出力されるはず
      expect(outputs.isNotEmpty, isTrue);
    });

    testWidgets('disabled flag prevents scroll interception in alt buffer',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h'); // alt buffer に切り替え
      testTerminal.write('\x1B[?1000h'); // X11 mouse mode on

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              disabled: true, // スクロールインターセプトを無効化
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, -80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // disabled = true のためスクロールイベントが生成されない
      expect(outputs.isEmpty, isTrue,
          reason: 'disabled interceptor must not send any scroll events');
    });

    testWidgets('ignores horizontal swipe in alt buffer', (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h');
      testTerminal.write('\x1B[?1000h');

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // 水平スワイプ（タブ切替用）は無視されるべき
      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      await gesture.moveBy(const Offset(100, 0)); // 横方向
      await gesture.up();
      await tester.pump();

      // 水平スワイプではスクロールイベントが生成されない
      expect(outputs.isEmpty, isTrue);
    });

    // _sendWheelEvent — SGR mouse report mode (?1006h)
    // SGR format: "\x1b[<buttonId;x;yM" (wheel up = "\x1b[<64;x;yM").
    // This is distinct from the normal "\x1b[M..." format and is the preferred mode
    // used by modern terminals (neovim, tmux, etc.).
    // Natural-scroll convention on touch: dragging finger DOWN triggers wheel UP (64).
    testWidgets('sends SGR-format escape sequence when SGR mode is enabled',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h'); // alt buffer
      testTerminal.write('\x1B[?1000h'); // mouse mode = upDownScroll
      testTerminal.write('\x1B[?1006h'); // report mode = SGR

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger DOWN (Offset +80) → terminal wheel UP (button 64).
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, 80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // SGR format: "\x1b[<64;x;yM" (wheel up = button 64)
      expect(
        outputs.any((o) => o.startsWith('\x1b[<64;')),
        isTrue,
        reason: 'SGR mode must generate "\\x1b[<64;x;yM" for wheel up',
      );
    });

    // _sendWheelEvent — URXVT mouse report mode (?1015h)
    // URXVT format: "\x1b[32+buttonId;x;yM" (wheel up → 32+64=96 → "\x1b[96;x;yM").
    // Natural-scroll convention on touch: dragging finger DOWN triggers wheel UP (64).
    testWidgets('sends URXVT-format escape sequence when URXVT mode is enabled',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h'); // alt buffer
      testTerminal.write('\x1B[?1000h'); // mouse mode = upDownScroll
      testTerminal.write('\x1B[?1015h'); // report mode = URXVT

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger DOWN (Offset +80) → terminal wheel UP (button 64).
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, 80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // URXVT format: "\x1b[96;x;yM" (32 + 64 = 96, wheel up)
      expect(
        outputs.any((o) => o.startsWith('\x1b[96;')),
        isTrue,
        reason: 'URXVT mode must generate "\\x1b[96;x;yM" for wheel up '
            '(32 + _kWheelUpButton=64)',
      );
    });

    // _sendWheelEvent — normal (default) mouse report mode.
    // When ?1006h (SGR) and ?1015h (URXVT) are NOT sent, the report mode is
    // normal (the xterm default).  Normal format: "\x1b[M" followed by three
    // raw bytes (each encoded as 32 + value).  Wheel-up button is 64, so the
    // 4th byte of the sequence must be chr(32+64) = chr(96) = '`'.
    // Natural-scroll convention on touch: dragging finger DOWN triggers wheel UP (64).
    testWidgets(
        'sends normal-format escape sequence when no report mode override',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h'); // alt buffer
      testTerminal.write('\x1B[?1000h'); // mouse mode = upDownScroll
      // No ?1006h or ?1015h — report mode stays at the default: normal.

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger DOWN (+80) → terminal wheel UP (button 64).
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, 80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // Normal format: "\x1b[M" + chr(96) + chr(col+32) + chr(row+32)
      // The 4th character (index 3) encodes the button: chr(32 + 64) = 96 = '`'.
      expect(
        outputs.any((o) =>
            o.startsWith('\x1b[M') &&
            o.length >= 6 &&
            o.codeUnitAt(3) == 96), // chr(32 + _kWheelUpButton=64)
        isTrue,
        reason:
            'normal mode must produce "\\x1b[M`<col><row>" for wheel up (button 64)',
      );
    });

    // _sendWheelEvent — wheel down corrects the xterm button-ID bug.
    // The xterm package mistakenly uses button IDs 68/69 for wheel up/down.
    // X11 standard requires 64/65. This test verifies button 65 (not 69) for
    // wheel down.
    // Natural-scroll convention on touch: dragging finger UP triggers wheel DOWN (65).
    testWidgets('sends wheel-down button 65 (X11 standard, not xterm bug 69)',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h'); // alt buffer
      testTerminal.write('\x1B[?1000h'); // mouse mode = upDownScroll
      testTerminal.write('\x1B[?1006h'); // SGR for human-readable button IDs

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger UP (Offset -80) → terminal wheel DOWN (button 65).
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, -80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // SGR format for wheel down: "\x1b[<65;x;yM" (not "\x1b[<69;x;yM")
      expect(
        outputs.any((o) => o.startsWith('\x1b[<65;')),
        isTrue,
        reason: 'wheel down must use button 65 (X11 standard), not 69 (xterm bug)',
      );
      // Confirm wheel up (64) was NOT sent
      expect(
        outputs.any((o) => o.startsWith('\x1b[<64;')),
        isFalse,
        reason: 'wheel down must not generate wheel-up (64) events',
      );
    });

    // _sendWheelEvent — arrow key fallback when mouseMode is none.
    // When no mouse mode is enabled (no ?1000h), _sendWheelEvent returns false
    // and the interceptor falls back to terminal.keyInput(arrowKey).
    // Natural-scroll convention: finger DOWN → arrowUp ("\x1b[A"),
    //                             finger UP   → arrowDown ("\x1b[B").
    testWidgets('falls back to arrowUp key when mouseMode is none',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h'); // alt buffer — required for interception
      // No ?1000h → mouseMode stays MouseMode.none.
      // _sendWheelEvent() returns false, so keyInput(arrowUp) is invoked instead.

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger DOWN (+80) → arrowUp (content scrolls up).
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, 80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // Arrow up escape sequence in ANSI mode: "\x1b[A"
      expect(
        outputs.any((o) => o == '\x1b[A'),
        isTrue,
        reason: 'with mouseMode=none, finger-down must send arrowUp ("\\x1b[A")',
      );
      // Verify no mouse wheel sequences were sent
      expect(
        outputs.any((o) => o.startsWith('\x1b[<') || o.startsWith('\x1b[M')),
        isFalse,
        reason: 'mouse wheel sequences must not be generated when mouseMode is none',
      );
    });

    // -------------------------------------------------------------------------
    // Alt-buffer exit mid-drag
    //
    // If the user starts a vertical touch drag while in alt buffer, then the
    // application exits alt buffer mid-gesture (e.g. the user quits tmux or
    // vim), _onPointerMove must call _reset() and stop generating scroll events.
    // This verifies the guard at the top of _onPointerMove:
    //   if (!widget.terminal.isUsingAltBuffer) { _reset(); return; }
    // -------------------------------------------------------------------------
    testWidgets('exits alt buffer mid-drag and stops sending scroll events',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: outputs.add,
      );
      testTerminal.write('\x1B[?1049h'); // enter alt buffer
      testTerminal.write('\x1B[?1000h'); // X11 mouse mode — enables wheel events
      testTerminal.write('\x1B[?1006h'); // SGR report mode for readable output

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.touch);

      // Move enough to decide direction (> 10px threshold) and accumulate two
      // line-heights (lineHeight = 20.0 when terminal.viewHeight <= 0).
      await gesture.moveBy(const Offset(0, 15)); // decides vertical direction
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40)); // 55px total → 2 events
      await tester.pump();

      final countBeforeExit = outputs.length;
      expect(countBeforeExit, greaterThan(0),
          reason: 'pre-condition: scroll events must be generated before alt-buffer exit');

      // Exit alt buffer while the gesture is still active.
      testTerminal.write('\x1B[?1049l');

      // Continue moving — _onPointerMove now sees isUsingAltBuffer == false
      // and must call _reset() immediately without sending any further events.
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();

      await gesture.up();
      await tester.pump();

      expect(outputs.length, equals(countBeforeExit),
          reason: 'no scroll events must be generated after alt-buffer exit');
    });

    // -------------------------------------------------------------------------
    // Wheel accumulator reset on alt-buffer exit
    //
    // _onScrollNotification accumulates fractional line-heights in
    // _wheelAccumulator across scroll events. If the user exits alt buffer
    // while the accumulator holds a residual (0 < residual < lineHeight),
    // then re-enters alt buffer and scrolls, the residual can push the
    // accumulator over lineHeight and fire a spurious scroll event.
    //
    // The fix: _onScrollNotification resets _wheelAccumulator = 0.0 whenever
    // !isUsingAltBuffer so each alt-buffer session starts clean.
    //
    // lineHeight defaults to 20.0 when terminal.viewHeight <= 0 (in tests).
    // A SingleChildScrollView child lets us inject precise ScrollNotifications
    // via ScrollController.jumpTo() without needing a real xterm widget.
    // -------------------------------------------------------------------------
    testWidgets(
        'resets wheel accumulator on alt-buffer exit to prevent spurious scroll on re-entry',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: outputs.add,
      );
      testTerminal.write('\x1B[?1049h'); // enter alt buffer
      // No ?1000h → mouseMode=none → keyInput fallback (arrowUp/Down sequences)

      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: SingleChildScrollView(
                controller: scrollController,
                child: const SizedBox(height: 2000, width: 300),
              ),
            ),
          ),
        ),
      );

      // Phase 1: scroll 15px while in alt buffer.
      // lineHeight = 25.0 (= 600/24 in the test environment) → 15 < 25,
      // no event fires, but leaves residual 15 in _wheelAccumulator.
      scrollController.jumpTo(15.0);
      await tester.pump();
      expect(outputs.isEmpty, isTrue,
          reason: 'pre-condition: 15px < lineHeight(25) must not fire an event');

      // Exit alt buffer while residual 15 sits in _wheelAccumulator.
      testTerminal.write('\x1B[?1049l');

      // Trigger a ScrollNotification while !altBuffer to exercise the reset path.
      scrollController.jumpTo(25.0); // delta=10, !altBuffer → resets accumulator
      await tester.pump();

      // Jump back to 0 for a clean starting position.
      scrollController.jumpTo(0.0);
      await tester.pump();

      // Re-enter alt buffer.
      testTerminal.write('\x1B[?1049h');

      // Phase 2: scroll 15px again.
      // With fix:    accumulator = 0 + 15 = 15 < 25 → no event.
      // Without fix: accumulator = 15 (residual) + 15 = 30 ≥ 25 → spurious arrowUp fires.
      scrollController.jumpTo(15.0);
      await tester.pump();

      expect(
        outputs.isEmpty,
        isTrue,
        reason: 'wheel accumulator must reset on alt-buffer exit; '
            'stale residual (15px) + new scroll (15px) = 30px ≥ lineHeight(25px) '
            'would fire a spurious arrowUp without the fix',
      );
    });

    // -------------------------------------------------------------------------
    // _onScrollNotification → _sendWheelEvent path with mouse mode enabled
    //
    // The "resets wheel accumulator" test above already exercises the
    // _onScrollNotification → keyInput fallback (mouseMode=none).  This test
    // covers the complementary path: when a mouse mode IS enabled, a
    // ScrollUpdateNotification from a child Scrollable must be converted into
    // a proper mouse wheel escape sequence (not an arrow key).
    //
    // Setup: alt buffer + upDownScroll (?1000h) + SGR (?1006h).
    // A SingleChildScrollView with ScrollController allows precise
    // ScrollUpdateNotification injection without a real xterm widget.
    //
    // In the Flutter test environment, all widgets render at the default
    // screen size (800×600) regardless of SizedBox constraints.
    // terminal.viewHeight defaults to 24, so lineHeight = 600/24 = 25.0.
    // jumpTo(50.0) from 0 → scrollDelta = +50 → _wheelAccumulator = 50 ≥ 25
    // → fires 2 events, both with isUp=false.
    // → _sendWheelEvent(false, x, y) → SGR "\x1b[<65;x;yM" (wheel down).
    // -------------------------------------------------------------------------
    testWidgets(
        'scroll notification in alt buffer with mouse mode sends SGR wheel-down event',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: outputs.add,
      );
      testTerminal.write('\x1B[?1049h'); // enter alt buffer
      testTerminal.write('\x1B[?1000h'); // mouse mode = upDownScroll
      testTerminal.write('\x1B[?1006h'); // SGR report mode

      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: SingleChildScrollView(
                controller: scrollController,
                child: const SizedBox(height: 2000, width: 300),
              ),
            ),
          ),
        ),
      );

      // lineHeight = 600 / 24 = 25.0 in the test environment.
      // jumpTo(50.0) accumulates 50 ≥ 25 → fires at least one wheel-down event.
      scrollController.jumpTo(50.0);
      await tester.pump();

      // _onScrollNotification: dy=+50, accumulator≥25 → isUp=false
      // → _sendWheelEvent(false, x, y) → SGR "\x1b[<65;x;yM" (wheel down)
      expect(
        outputs.any((o) => o.startsWith('\x1b[<65;')),
        isTrue,
        reason: 'scroll-notification path must send SGR wheel-down (button 65) '
            'when mouse mode is enabled in alt buffer',
      );
      // Confirm no arrow-key fallback was used
      expect(
        outputs.any((o) => o == '\x1b[A' || o == '\x1b[B'),
        isFalse,
        reason: 'no arrow-key fallback when _sendWheelEvent succeeds',
      );
    });

    // -------------------------------------------------------------------------
    // Multi-line scroll accumulator via _onScrollNotification
    //
    // When jumpTo(75.0) fires a ScrollUpdateNotification with scrollDelta=75,
    // the accumulator loop fires 3 times (75 / 25 = 3 lines) — one renderBox
    // lookup must serve all three iterations.
    //
    // lineHeight = 600/24 = 25.0 in the test environment (800×600 default size,
    // terminal.viewHeight = 24).
    // -------------------------------------------------------------------------
    testWidgets(
        'scroll notification fires correct number of events for multi-line delta',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: outputs.add,
      );
      testTerminal.write('\x1B[?1049h'); // enter alt buffer
      testTerminal.write('\x1B[?1000h'); // mouse mode = upDownScroll
      testTerminal.write('\x1B[?1006h'); // SGR report mode

      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: SingleChildScrollView(
                controller: scrollController,
                child: const SizedBox(height: 2000, width: 300),
              ),
            ),
          ),
        ),
      );

      // lineHeight = 600 / 24 = 25.0 in the test environment.
      // jumpTo(75.0) from 0: scrollDelta = +75 → accumulator = 75 → 3 ticks.
      // Each tick: isUp=false → _sendWheelEvent(false, x, y) → "\x1b[<65;x;yM".
      scrollController.jumpTo(75.0);
      await tester.pump();

      final wheelDownEvents =
          outputs.where((o) => o.startsWith('\x1b[<65;')).toList();
      expect(
        wheelDownEvents.length,
        3,
        reason: 'scrollDelta=75 with lineHeight=25 must fire exactly 3 '
            'wheel-down events from the accumulator loop',
      );
      expect(
        outputs.any((o) => o.startsWith('\x1b[<64;')),
        isFalse,
        reason: 'no wheel-up events should be sent for a downward scroll',
      );
    });

    testWidgets('falls back to arrowDown key when mouseMode is none',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: (data) {
          outputs.add(data);
        },
      );
      testTerminal.write('\x1B[?1049h'); // alt buffer
      // No ?1000h → mouseMode stays MouseMode.none.

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger UP (-80) → arrowDown (content scrolls down).
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, -80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // Arrow down escape sequence in ANSI mode: "\x1b[B"
      expect(
        outputs.any((o) => o == '\x1b[B'),
        isTrue,
        reason: 'with mouseMode=none, finger-up must send arrowDown ("\\x1b[B")',
      );
    });

    // _sendWheelEvent — clickOnly mouse mode (X10 / ?9h) falls back to arrow keys.
    //
    // MouseMode.clickOnly only reports button press/release coordinates; it does
    // not handle wheel scroll events.  _sendWheelEvent treats clickOnly the same
    // as none (returns false), so the interceptor must fall back to
    // terminal.keyInput(arrowKey) just as it does for mouseMode=none.
    //
    // Natural-scroll convention: finger DOWN → arrowUp ("\x1b[A").
    testWidgets(
        'falls back to arrowUp key when mouseMode is clickOnly (?9h)',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: outputs.add,
      );
      testTerminal.write('\x1B[?1049h'); // enter alt buffer
      testTerminal.write('\x1B[?9h');    // X10 mouse mode → MouseMode.clickOnly

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger DOWN (+80) → arrowUp (content scrolls up).
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, 80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      expect(
        outputs.any((o) => o == '\x1b[A'),
        isTrue,
        reason: 'clickOnly mode does not handle wheel events; '
            'interceptor must fall back to arrowUp ("\\x1b[A")',
      );
      // Confirm no mouse wheel sequences were sent (clickOnly mode cannot handle them).
      expect(
        outputs.any((o) => o.startsWith('\x1b[<') || o.startsWith('\x1b[M')),
        isFalse,
        reason: 'mouse wheel sequences must not be generated when mouseMode is clickOnly',
      );
    });

    // Complementary: clickOnly + finger UP → arrowDown.
    testWidgets(
        'falls back to arrowDown key when mouseMode is clickOnly (?9h)',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: outputs.add,
      );
      testTerminal.write('\x1B[?1049h');
      testTerminal.write('\x1B[?9h'); // MouseMode.clickOnly

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger UP (-80) → arrowDown (content scrolls down).
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, -80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      expect(
        outputs.any((o) => o == '\x1b[B'),
        isTrue,
        reason: 'clickOnly mode must fall back to arrowDown ("\\x1b[B") '
            'when finger moves up',
      );
    });

    // -------------------------------------------------------------------------
    // Long-press detection cancels scroll interception
    //
    // If the user holds their finger for _kLongPressDelay (300 ms) without
    // moving much (<20 px total displacement), the interceptor treats the
    // gesture as a long-press (e.g. for text selection) and calls _reset().
    //
    // After reset, subsequent pointer-move events are ignored because
    // _activePointerId is cleared, so no scroll events are generated even if
    // the finger moves a large distance later.
    //
    // The refactored implementation uses a Timer (instead of DateTime.now()),
    // so tester.pump(Duration) reliably advances the fake clock.
    // -------------------------------------------------------------------------
    testWidgets(
        'long-press (300 ms, tiny movement) cancels scroll interception',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: outputs.add,
      );
      testTerminal.write('\x1B[?1049h'); // enter alt buffer
      testTerminal.write('\x1B[?1000h'); // X11 mouse mode
      testTerminal.write('\x1B[?1006h'); // SGR for readable output

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));

      // Finger down — starts the 300 ms long-press timer.
      final gesture = await tester.startGesture(center,
          kind: PointerDeviceKind.touch);

      // Advance 310 ms: fires the long-press timer (_longPressActivated = true).
      await tester.pump(const Duration(milliseconds: 310));

      // Move only 5 px (< 20 px threshold) — triggers long-press reset path.
      await gesture.moveBy(const Offset(0, 5));
      await tester.pump();

      // Continue dragging a large distance — must produce no scroll events
      // because _reset() cleared _activePointerId and subsequent moves are ignored.
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(
        outputs.isEmpty,
        isTrue,
        reason: 'long-press must cancel scroll interception; '
            'no scroll events must be generated after the 300 ms threshold',
      );
    });

    // -------------------------------------------------------------------------
    // Early movement before long-press timer fires still scrolls correctly
    //
    // If the user moves more than 10 px before the 300 ms timer fires,
    // _directionDecided is set to true and the long-press check is never
    // reached. Subsequent movement must still produce scroll events normally.
    // -------------------------------------------------------------------------
    testWidgets(
        'quick movement before long-press timer fires still scrolls',
        (tester) async {
      final outputs = <String>[];
      final testTerminal = Terminal(
        maxLines: 100,
        onOutput: outputs.add,
      );
      testTerminal.write('\x1B[?1049h'); // enter alt buffer
      testTerminal.write('\x1B[?1000h'); // X11 mouse mode
      testTerminal.write('\x1B[?1006h'); // SGR

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 400,
            child: TerminalScrollInterceptor(
              terminal: testTerminal,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );

      // Natural scroll: finger DOWN (+80) before the 300 ms timer fires.
      // This exceeds both the 10 px direction-decision threshold and
      // the 20 px long-press displacement threshold.
      await tester.drag(
        find.byType(TerminalScrollInterceptor),
        const Offset(0, 80),
        kind: PointerDeviceKind.touch,
        warnIfMissed: false,
      );
      await tester.pump();

      // Scroll events must still be generated (long-press timer never activated).
      expect(
        outputs.isNotEmpty,
        isTrue,
        reason: 'quick vertical movement must still produce scroll events '
            'when long-press timer has not yet fired',
      );
    });
  });
}
