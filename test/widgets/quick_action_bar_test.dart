import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:terminal_ssh_app/widgets/quick_action_bar.dart';

void main() {
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
