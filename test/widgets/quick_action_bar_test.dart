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
      await tester.pumpAndSettle();
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
