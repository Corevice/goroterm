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

      // 垂直スワイプを実行（方向判定閾値10pxを超えて、さらに複数行分スクロール）
      final center = tester.getCenter(find.byType(TerminalScrollInterceptor));
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.touch);
      await gesture.moveBy(const Offset(0, -80));
      await gesture.up();
      await tester.pump();

      // mouseInput が呼ばれてエスケープシーケンスが出力されるはず
      expect(outputs.isNotEmpty, isTrue);
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
  });
}
