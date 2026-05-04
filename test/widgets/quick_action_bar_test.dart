import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:terminal_ssh_app/widgets/quick_action_bar.dart';

void main() {
  group('QuickActionBar optional callbacks', () {
    testWidgets('Claude button hidden when onClaudeCommand is null',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.auto_awesome), findsNothing);
    });

    testWidgets('Claude button shown and tappable when onClaudeCommand provided',
        (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onClaudeCommand: () => called = true,
          ),
        ),
      ));
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
      await tester.tap(find.byIcon(Icons.auto_awesome));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('image paste button hidden when onImagePaste is null',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.attach_file), findsNothing);
    });

    testWidgets('image paste button shown and tappable when provided',
        (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onImagePaste: () => called = true,
          ),
        ),
      ));
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.attach_file));
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('clipboard paste button hidden when onClipboardPaste is null',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.content_paste), findsNothing);
    });

    testWidgets('clipboard paste button shown and tappable when provided',
        (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onClipboardPaste: () => called = true,
          ),
        ),
      ));
      expect(find.byIcon(Icons.content_paste), findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.content_paste));
      await tester.tap(find.byIcon(Icons.content_paste));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('select mode button hidden when onToggleSelectMode is null',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.text_fields), findsNothing);
    });

    testWidgets('select mode button shown and tappable when provided',
        (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onToggleSelectMode: () => called = true,
          ),
        ),
      ));
      expect(find.byIcon(Icons.text_fields), findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.text_fields));
      await tester.tap(find.byIcon(Icons.text_fields));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('scroll to top button calls callback', (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onScrollToTop: () => called = true,
          ),
        ),
      ));
      await tester.tap(find.byIcon(Icons.vertical_align_top));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('scroll to bottom button calls callback', (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onScrollToBottom: () => called = true,
          ),
        ),
      ));
      await tester.tap(find.byIcon(Icons.vertical_align_bottom));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('PgUp button calls callback', (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onPageUp: () => called = true,
          ),
        ),
      ));
      await tester.ensureVisible(find.text('PgUp'));
      await tester.tap(find.text('PgUp'));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('PgDn button calls callback', (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onPageDown: () => called = true,
          ),
        ),
      ));
      await tester.ensureVisible(find.text('PgDn'));
      await tester.tap(find.text('PgDn'));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('symbol buttons send correct text input', (tester) async {
      final inputs = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: inputs.add,
          ),
        ),
      ));
      await tester.ensureVisible(find.text('/'));
      await tester.tap(find.text('/'));
      await tester.pump();
      await tester.ensureVisible(find.text('-'));
      await tester.tap(find.text('-'));
      await tester.pump();
      await tester.ensureVisible(find.text('|'));
      await tester.tap(find.text('|'));
      await tester.pump();
      expect(inputs, ['/', '-', '|']);
    });

    testWidgets('select mode button shows active/inactive styles', (tester) async {
      var selectMode = false;

      Widget buildWithSelectMode(bool isSelectMode) => MaterialApp(
            home: Scaffold(
              body: QuickActionBar(
                onKeyPressed: (key, {ctrl = false}) {},
                onTextInput: (_) {},
                onToggleSelectMode: () => selectMode = !selectMode,
                isSelectMode: isSelectMode,
              ),
            ),
          );

      await tester.pumpWidget(buildWithSelectMode(false));
      final inactiveFinder = find.byIcon(Icons.text_fields);
      expect(inactiveFinder, findsOneWidget);

      await tester.pumpWidget(buildWithSelectMode(true));
      final activeFinder = find.byIcon(Icons.text_fields);
      expect(activeFinder, findsOneWidget);
    });
  });

  group('_RepeatableActionButton', () {
    testWidgets('short tap sends exactly one key event', (tester) async {
      final calls = <TerminalKey>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) => calls.add(key),
            onTextInput: (_) {},
          ),
        ),
      ));

      // Quick tap (shorter than activation delay 80ms)
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump(const Duration(milliseconds: 50));

      expect(calls, [TerminalKey.arrowUp]);
    });

    testWidgets('long press triggers repeat events', (tester) async {
      final calls = <TerminalKey>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) => calls.add(key),
            onTextInput: (_) {},
          ),
        ),
      ));

      // Press and hold past activation delay (80ms) + repeat start delay (200ms)
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.arrow_upward)),
      );
      await tester.pump(const Duration(milliseconds: 90)); // pass activation
      // First press fires at activation
      expect(calls.length, 1);
      expect(calls.first, TerminalKey.arrowUp);

      // After repeat start delay (200ms) + a few 50ms ticks
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      // Should have additional calls from periodic timer
      expect(calls.length, greaterThan(2));

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 10));
    });

    // -------------------------------------------------------------------------
    // medium-tap path: pointer-up after activation (80ms) but before the
    // repeat-start timer fires (80ms + 200ms = 280ms).
    //
    // _startRepeat() fires at 80ms → _isPressed = true, 1 event sent, a 200ms
    // one-shot timer is started that would kick off the periodic repeat.
    // Before that 200ms elapses the finger is lifted, so _stopRepeat() is
    // called.  At that point:
    //   wasPendingActivation = false  (activation timer already fired)
    //   _isPressed            = true  (set by _startRepeat)
    // → the "short tap" branch (wasPendingActivation && !_isPressed) is false
    //   → no duplicate event is added
    //   → the 200ms timer is cancelled → no repeat events ever fire
    //
    // Expected: exactly 1 event total.
    // -------------------------------------------------------------------------
    testWidgets(
        'medium tap (between activation and repeat start) sends exactly one event',
        (tester) async {
      final calls = <TerminalKey>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) => calls.add(key),
            onTextInput: (_) {},
          ),
        ),
      ));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.arrow_upward)),
      );
      // Past activation delay (80ms) → _startRepeat fires, 1 event sent.
      await tester.pump(const Duration(milliseconds: 90));
      expect(calls.length, 1, reason: 'activation should have fired once');

      // Lift finger before the 200ms repeat-start timer elapses.
      await gesture.up();
      await tester.pump();

      // No extra event from the short-tap branch.
      expect(calls.length, 1,
          reason: '_isPressed=true suppresses duplicate tap event');

      // Advance well past repeat-start delay to confirm the timer was cancelled.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls.length, 1,
          reason: 'repeat timer must have been cancelled on pointer-up');
    });

    testWidgets('horizontal swipe cancels and sends no events', (tester) async {
      final calls = <TerminalKey>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: QuickActionBar(
              onKeyPressed: (key, {ctrl = false}) => calls.add(key),
              onTextInput: (_) {},
            ),
          ),
        ),
      ));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.arrow_upward)),
      );
      // Move horizontally beyond the 8px threshold
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pump();

      expect(calls, isEmpty);
    });

    // -------------------------------------------------------------------------
    // onPointerCancel path (system-level gesture cancellation)
    //
    // When the OS cancels the pointer (e.g., another gesture recognizer wins,
    // or a phone call interrupts), the Listener fires onPointerCancel which
    // calls _cancel(). This must stop any pending/running timers and send no
    // additional key events.
    // -------------------------------------------------------------------------

    testWidgets('pointer cancel before activation fires sends no events',
        (tester) async {
      final calls = <TerminalKey>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) => calls.add(key),
            onTextInput: (_) {},
          ),
        ),
      ));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.arrow_upward)),
      );
      // Cancel before the 80ms activation delay elapses.
      await tester.pump(const Duration(milliseconds: 30));
      await gesture.cancel();
      await tester.pump(const Duration(milliseconds: 10));

      expect(calls, isEmpty,
          reason: 'cancel before activation must not send any key event');
    });

    testWidgets('pointer cancel during long press stops the repeat',
        (tester) async {
      final calls = <TerminalKey>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) => calls.add(key),
            onTextInput: (_) {},
          ),
        ),
      ));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.arrow_upward)),
      );
      // Pass activation delay (80ms) — first key is sent.
      await tester.pump(const Duration(milliseconds: 90));
      // Pass repeat start delay (200ms) and two 50ms ticks — repeat is running.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      final countAtCancel = calls.length;
      expect(countAtCancel, greaterThan(1),
          reason: 'should have at least the activation press + repeat events');

      // System cancels the gesture.
      await gesture.cancel();
      // Let more time pass — the repeat timer must have been cancelled.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(calls.length, equals(countAtCancel),
          reason: 'no further key events should fire after pointer cancel');
    });

    // -------------------------------------------------------------------------
    // deactivate() path: GlobalKey reparenting
    //
    // When QuickActionBar is moved to a different parent in the widget tree
    // (GlobalKey reparenting), Flutter calls deactivate() on all descendant
    // states — including _RepeatableActionButtonState — without calling
    // dispose(). The deactivate() override must cancel any running timers so
    // no stale events fire after the widget is re-activated at its new position.
    // -------------------------------------------------------------------------
    testWidgets(
        'deactivate during repeat stops the timer and prevents further events',
        (tester) async {
      final calls = <TerminalKey>[];
      final barKey = GlobalKey();

      // Helper: build the bar optionally wrapped in an extra Container.
      // Switching between the two builds reparents the bar (GlobalKey move).
      Widget buildWrapper({required bool inContainer}) {
        final bar = QuickActionBar(
          key: barKey,
          onKeyPressed: (key, {ctrl = false}) => calls.add(key),
          onTextInput: (_) {},
        );
        return MaterialApp(
          home: Scaffold(
            body: inContainer ? Container(child: bar) : bar,
          ),
        );
      }

      await tester.pumpWidget(buildWrapper(inContainer: true));

      // Start a long press: wait past activation delay (80ms) and repeat-start
      // delay (200ms), then let a couple of 50ms repeat ticks fire.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.arrow_upward)),
      );
      await tester.pump(const Duration(milliseconds: 90)); // activation fires
      await tester.pump(const Duration(milliseconds: 200)); // repeat-start delay
      await tester.pump(const Duration(milliseconds: 50)); // first repeat tick

      final countBeforeDeactivate = calls.length;
      expect(countBeforeDeactivate, greaterThan(1),
          reason: 'should have activation press + at least one repeat event');

      // Reparent: move bar from inside Container to direct Scaffold body.
      // Flutter recognises the GlobalKey, calls deactivate() on the subtree
      // (including _RepeatableActionButtonState), moves it, then calls activate().
      // dispose() is NOT called — the state is preserved for the new position.
      await tester.pumpWidget(buildWrapper(inContainer: false));
      await tester.pump();

      // Advance time well beyond repeat intervals.  The repeat timer must have
      // been cancelled by deactivate(), so no new events should fire.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls.length, equals(countBeforeDeactivate),
          reason: 'deactivate() must cancel the repeat timer');

      await gesture.cancel();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  group('QuickActionBar voice input button', () {
    testWidgets('voice button hidden when onVoiceInput is null', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(find.byIcon(Icons.mic_none), findsNothing);
    });

    testWidgets('voice button shown and tappable when onVoiceInput provided',
        (tester) async {
      var called = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onVoiceInput: () => called = true,
          ),
        ),
      ));
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.mic_none));
      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets('shows Icons.mic when isListening is true', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onVoiceInput: () {},
            isListening: true,
          ),
        ),
      ));
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsNothing);
    });

    testWidgets('shows Icons.mic_none when isListening is false', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) {},
            onTextInput: (_) {},
            onVoiceInput: () {},
            isListening: false,
          ),
        ),
      ));
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
    });
  });

  group('QuickActionBar shortcut buttons (Phase 16)', () {
    late List<(TerminalKey, bool)> calls;

    Widget buildBar() {
      return MaterialApp(
        home: Scaffold(
          body: QuickActionBar(
            onKeyPressed: (key, {ctrl = false}) => calls.add((key, ctrl)),
            onTextInput: (_) {},
          ),
        ),
      );
    }

    setUp(() {
      calls = [];
    });

    testWidgets('C-c button sends Ctrl+C', (tester) async {
      await tester.pumpWidget(buildBar());
      await tester.tap(find.text('C-c'));
      await tester.pump();
      expect(calls, [(TerminalKey.keyC, true)]);
    });

    testWidgets('C-d button sends Ctrl+D', (tester) async {
      await tester.pumpWidget(buildBar());
      await tester.tap(find.text('C-d'));
      await tester.pump();
      expect(calls, [(TerminalKey.keyD, true)]);
    });

    testWidgets('C-j button sends Ctrl+J', (tester) async {
      await tester.pumpWidget(buildBar());
      await tester.tap(find.text('C-j'));
      await tester.pump();
      expect(calls, [(TerminalKey.keyJ, true)]);
    });

    testWidgets('C-c, C-d, C-j buttons are all present', (tester) async {
      await tester.pumpWidget(buildBar());
      expect(find.text('C-c'), findsOneWidget);
      expect(find.text('C-d'), findsOneWidget);
      expect(find.text('C-j'), findsOneWidget);
    });

    testWidgets('Ctrl menu contains J entry', (tester) async {
      await tester.pumpWidget(buildBar());
      await tester.tap(find.text('Ctrl'));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl+J'), findsOneWidget);
    });

    testWidgets('Ctrl+J from menu sends keyJ with ctrl=true', (tester) async {
      await tester.pumpWidget(buildBar());
      await tester.tap(find.text('Ctrl'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ctrl+J'));
      await tester.pumpAndSettle();
      expect(calls, [(TerminalKey.keyJ, true)]);
    });

    // All Ctrl menu entries and their expected TerminalKey values.
    const ctrlMenuEntries = <(String, TerminalKey)>[
      ('A', TerminalKey.keyA),
      ('C', TerminalKey.keyC),
      ('D', TerminalKey.keyD),
      ('E', TerminalKey.keyE),
      ('K', TerminalKey.keyK),
      ('L', TerminalKey.keyL),
      ('R', TerminalKey.keyR),
      ('U', TerminalKey.keyU),
      ('W', TerminalKey.keyW),
      ('Z', TerminalKey.keyZ),
    ];

    for (final (char, expectedKey) in ctrlMenuEntries) {
      testWidgets('Ctrl+$char from menu sends key$char with ctrl=true',
          (tester) async {
        await tester.pumpWidget(buildBar());
        await tester.tap(find.text('Ctrl'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ctrl+$char'));
        await tester.pumpAndSettle();
        expect(calls, [(expectedKey, true)]);
      });
    }

    testWidgets('Ctrl menu shows all 11 entries', (tester) async {
      await tester.pumpWidget(buildBar());
      await tester.tap(find.text('Ctrl'));
      await tester.pumpAndSettle();
      const keys = ['C', 'D', 'J', 'Z', 'A', 'E', 'L', 'R', 'K', 'U', 'W'];
      for (final key in keys) {
        expect(find.text('Ctrl+$key'), findsOneWidget,
            reason: 'Ctrl+$key should be in the menu');
      }
    });
  });
}
