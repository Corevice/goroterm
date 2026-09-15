import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/core/error/app_error.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_manager_screen.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_provider.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_session_model.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';

import '../../test_localizations.dart';

// ---------------------------------------------------------------------------
// Shared state variable
// ---------------------------------------------------------------------------

TmuxState _fakeTmuxState = TmuxState(
  availability: const TmuxAvailable(version: 'tmux 3.3a'),
);

/// When true, [_FakeTmuxNotifier.createSession] throws
/// TmuxError(notConnected) instead of succeeding. Reset it in tearDown.
bool _throwNotConnectedOnCreate = false;

/// When set, [_FakeTmuxNotifier.refresh] returns this Completer's future
/// instead of resolving immediately — lets tests control exactly when an
/// in-flight refresh() completes. Reset it (to null) in tearDown.
Completer<bool>? _refreshCompleter;

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeTmuxNotifier extends TmuxNotifier {
  @override
  Future<TmuxState> build(String arg) async => _fakeTmuxState;

  @override
  Future<bool> refresh() {
    final completer = _refreshCompleter;
    if (completer != null) return completer.future;
    return Future.value(true);
  }

  @override
  Future<bool> createSession(String name) async {
    if (_throwNotConnectedOnCreate) {
      throw const TmuxError(
        'Not connected to SSH session',
        reason: TmuxErrorReason.notConnected,
      );
    }
    return true;
  }

  @override
  Future<bool> killSession(String name) async => true;

  @override
  Future<bool> renameSession(String oldName, String newName) async => true;

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
    child: localizedTestApp(
      home: const Scaffold(
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
      _throwNotConnectedOnCreate = false;
      _refreshCompleter = null;
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
      // Use pump with explicit duration instead of pumpAndSettle to avoid
      // blocking on TextField cursor blink animation (infinite repeating timer).
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('New tmux Session'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    // ---------------------------------------------------------------------
    // brief C / test (e): a TmuxError(notConnected) SnackBar must appear
    // inside TmuxManagerScreen's own subtree (its new inner
    // ScaffoldMessenger), not swallowed by the outer Scaffold — see
    // _messengerKey's doc comment in tmux_manager_screen.dart.
    // ---------------------------------------------------------------------
    testWidgets(
        'shows the notConnected SnackBar inside TmuxManagerScreen when '
        'createSession throws TmuxError(notConnected)', (tester) async {
      _throwNotConnectedOnCreate = true;

      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField), 'my-session');
      await tester.pump();
      await tester.tap(find.text('Create'));
      // Let the dialog close and the async createSession()/catch run.
      await tester.pump();
      await tester.pump();

      final snackBarInDrawer = find.descendant(
        of: find.byType(TmuxManagerScreen),
        matching: find.byType(SnackBar),
      );
      expect(snackBarInDrawer, findsOneWidget,
          reason: 'the SnackBar must be shown by the drawer\'s own '
              'ScaffoldMessenger, not the outer one');
      expect(
        find.descendant(
          of: snackBarInDrawer,
          matching: find.text(
            'Not connected. Please try again after reconnecting.',
          ),
        ),
        findsOneWidget,
      );
    });

    // ---------------------------------------------------------------------
    // brief C / test (f): the header refresh button shows a progress
    // indicator while refresh() is in flight, and reverts once it resolves.
    // ---------------------------------------------------------------------
    testWidgets(
        'shows a progress indicator while manual refresh() is in flight, '
        'then reverts to the refresh icon', (tester) async {
      final completer = Completer<bool>();
      _refreshCompleter = completer;

      await tester.pumpWidget(_buildScreen());
      await tester.pump();

      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();

      // In-flight: the refresh icon is replaced by a small spinner and the
      // button is disabled (no separate IconButton to tap).
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete(true);
      await tester.pump();
      await tester.pump();

      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
