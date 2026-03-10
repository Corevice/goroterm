import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/features/file_browser/path_bar_widget.dart';

void main() {
  group('PathBarWidget', () {
    testWidgets('shows root segment for / path', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PathBarWidget(
              path: '/',
              onNavigate: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('/'), findsOneWidget);
    });

    testWidgets('shows all breadcrumb segments', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PathBarWidget(
              path: '/home/user/projects',
              onNavigate: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('/'), findsOneWidget);
      expect(find.text('home'), findsOneWidget);
      expect(find.text('user'), findsOneWidget);
      expect(find.text('projects'), findsOneWidget);
    });

    testWidgets('tapping intermediate segment calls onNavigate', (tester) async {
      String? navigatedPath;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PathBarWidget(
              path: '/home/user/projects',
              onNavigate: (path) => navigatedPath = path,
            ),
          ),
        ),
      );
      await tester.tap(find.text('home'));
      await tester.pumpAndSettle();
      expect(navigatedPath, '/home');
    });

    testWidgets('tapping last segment does not navigate', (tester) async {
      String? navigatedPath;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PathBarWidget(
              path: '/home/user',
              onNavigate: (path) => navigatedPath = path,
            ),
          ),
        ),
      );
      await tester.tap(find.text('user'));
      await tester.pump();
      expect(navigatedPath, isNull);
    });

    testWidgets('copy icon is present', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PathBarWidget(
              path: '/home/user',
              onNavigate: (_) {},
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.copy), findsOneWidget);
    });
  });

  group('shellEscapeForTerminal', () {
    test('delegates to shellEscapePath', () {
      expect(shellEscapeForTerminal('/path/to/file'), "'/path/to/file'");
      expect(
        shellEscapeForTerminal('/path with spaces'),
        "'/path with spaces'",
      );
    });
  });
}
