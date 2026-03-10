import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/features/tmux/tmux_manager_screen.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_provider.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_session_model.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';

// ---------------------------------------------------------------------------
// Shared state variable
// ---------------------------------------------------------------------------

TmuxState _fakeTmuxState = TmuxState(
  availability: const TmuxAvailable(version: 'tmux 3.3a'),
);

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeTmuxNotifier extends TmuxNotifier {
  @override
  Future<TmuxState> build(String arg) async => _fakeTmuxState;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> createSession(String name) async {}

  @override
  Future<void> killSession(String name) async {}

  @override
  Future<void> renameSession(String oldName, String newName) async {}

  @override
  void attachSession(String name) {}
}

class _FakeTerminalNotifier extends TerminalConnectionNotifier {
  @override
  TerminalConnectionState build(String arg) =>
      const TerminalConnectionState(status: ConnectionStatus.connected);
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

Widget _buildScreen() {
  return ProviderScope(
    overrides: [
      tmuxProvider.overrideWith(_FakeTmuxNotifier.new),
      terminalConnectionProvider.overrideWith(_FakeTerminalNotifier.new),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: TmuxManagerScreen(connectionId: 'conn1'),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('TmuxManagerScreen', () {
    setUp(() {
      _fakeTmuxState = TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
        sessions: [],
      );
    });

    testWidgets('shows "tmux Sessions" header', (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();
      expect(find.text('tmux Sessions'), findsOneWidget);
    });

    testWidgets('shows add icon in header', (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('shows refresh icon in header', (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('shows empty state message when no sessions', (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();
      expect(find.textContaining('No sessions'), findsOneWidget);
    });

    testWidgets('shows session list when sessions present', (tester) async {
      _fakeTmuxState = TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
        sessions: [
          TmuxSession(
            name: 'work',
            windowCount: 3,
            isAttached: true,
            createdAt: DateTime(2024, 1, 15),
          ),
          TmuxSession(
            name: 'personal',
            windowCount: 1,
            isAttached: false,
            createdAt: DateTime(2024, 2, 20),
          ),
        ],
      );
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      expect(find.text('work'), findsOneWidget);
      expect(find.text('personal'), findsOneWidget);
    });

    testWidgets('shows window count in session card', (tester) async {
      _fakeTmuxState = TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
        sessions: [
          TmuxSession(
            name: 'work',
            windowCount: 3,
            isAttached: false,
            createdAt: DateTime(2024, 1, 15),
          ),
        ],
      );
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      expect(find.textContaining('3 windows'), findsOneWidget);
    });

    testWidgets('shows not-installed view when tmux unavailable',
        (tester) async {
      _fakeTmuxState = TmuxState(availability: const TmuxNotInstalled());
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      expect(find.textContaining('not installed'), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
    });

    testWidgets('shows install commands when tmux not installed',
        (tester) async {
      _fakeTmuxState = TmuxState(availability: const TmuxNotInstalled());
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      expect(find.textContaining('apt install tmux'), findsOneWidget);
      expect(find.textContaining('brew install tmux'), findsOneWidget);
    });

    testWidgets('tapping + opens create session dialog', (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('New tmux Session'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });
  });
}
