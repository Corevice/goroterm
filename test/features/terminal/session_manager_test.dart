import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/features/terminal/session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer() => ProviderContainer();

  // -------------------------------------------------------------------------
  // SessionManagerState.copyWith — value-class behaviour
  // -------------------------------------------------------------------------

  group('SessionManagerState.copyWith', () {
    test('batteryWarning defaults to false', () {
      const state = SessionManagerState();
      expect(state.batteryWarning, isFalse);
    });

    test('copyWith sets batteryWarning to true', () {
      const state = SessionManagerState();
      final updated = state.copyWith(batteryWarning: true);
      expect(updated.batteryWarning, isTrue);
    });

    test('copyWith resets batteryWarning to false', () {
      const state = SessionManagerState(batteryWarning: true);
      final updated = state.copyWith(batteryWarning: false);
      expect(updated.batteryWarning, isFalse);
    });

    test('copyWith preserves batteryWarning when not specified', () {
      const state = SessionManagerState(batteryWarning: true);
      final updated = state.copyWith(activeSessionId: 'x');
      expect(updated.batteryWarning, isTrue);
    });

    test('clearActiveSessionId: true clears activeSessionId', () {
      const state = SessionManagerState(activeSessionId: 'session_1_1');
      final updated = state.copyWith(clearActiveSessionId: true);
      expect(updated.activeSessionId, isNull);
    });

    test('clearActiveSessionId: true takes precedence over activeSessionId', () {
      const state = SessionManagerState(activeSessionId: 'old');
      final updated = state.copyWith(
        clearActiveSessionId: true,
        activeSessionId: 'new',
      );
      expect(updated.activeSessionId, isNull);
    });

    test('clearActiveSessionId: false (default) preserves activeSessionId', () {
      const state = SessionManagerState(activeSessionId: 'session_1_1');
      final updated = state.copyWith(batteryWarning: true);
      expect(updated.activeSessionId, 'session_1_1');
    });

    test('copyWith preserves sessions when not specified', () {
      final session = TerminalSession(
        sessionId: 'sid',
        connectionId: 1,
        label: 'srv',
      );
      final state = SessionManagerState(sessions: [session]);
      final updated = state.copyWith(batteryWarning: true);
      expect(updated.sessions, same(state.sessions));
    });
  });

  group('SessionManagerNotifier', () {
    test('initial state has no sessions and no active session', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final state = container.read(sessionManagerProvider);
      expect(state.sessions, isEmpty);
      expect(state.activeSessionId, isNull);
    });

    test('addSession creates a session and sets it active', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id = notifier.addSession(connectionId: 1, label: 'My Server');

      final state = container.read(sessionManagerProvider);
      expect(state.sessions.length, 1);
      expect(state.sessions.first.sessionId, id);
      expect(state.sessions.first.connectionId, 1);
      expect(state.sessions.first.label, 'My Server');
      expect(state.activeSessionId, id);
    });

    test('addSession generates unique session IDs', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id1 = notifier.addSession(connectionId: 1, label: 'A');
      final id2 = notifier.addSession(connectionId: 1, label: 'B');

      expect(id1, isNot(equals(id2)));
    });

    test('addSession sets new session as active', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      notifier.addSession(connectionId: 1, label: 'First');
      final id2 = notifier.addSession(connectionId: 2, label: 'Second');

      expect(container.read(sessionManagerProvider).activeSessionId, id2);
    });

    test('setActiveSession switches active tab', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id1 = notifier.addSession(connectionId: 1, label: 'A');
      notifier.addSession(connectionId: 2, label: 'B');

      notifier.setActiveSession(id1);

      expect(container.read(sessionManagerProvider).activeSessionId, id1);
    });

    test('removeSession deletes the session', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id1 = notifier.addSession(connectionId: 1, label: 'A');
      notifier.addSession(connectionId: 2, label: 'B');

      notifier.removeSession(id1);

      final state = container.read(sessionManagerProvider);
      expect(state.sessions.length, 1);
      expect(state.sessions.any((s) => s.sessionId == id1), isFalse);
    });

    test('removeSession sets active to remaining session when active removed',
        () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id1 = notifier.addSession(connectionId: 1, label: 'A');
      final id2 = notifier.addSession(connectionId: 2, label: 'B');

      // id2 is now active. Remove it.
      notifier.removeSession(id2);

      final state = container.read(sessionManagerProvider);
      expect(state.activeSessionId, id1);
    });

    test('removeSession keeps active session when non-active session removed', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id1 = notifier.addSession(connectionId: 1, label: 'A');
      final id2 = notifier.addSession(connectionId: 2, label: 'B');

      // id2 is active. Remove id1 (non-active).
      notifier.removeSession(id1);

      final state = container.read(sessionManagerProvider);
      expect(state.sessions.length, 1);
      expect(state.activeSessionId, id2);
    });

    test('removeSession clears activeSessionId when last session removed', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id1 = notifier.addSession(connectionId: 1, label: 'A');
      notifier.removeSession(id1);

      final state = container.read(sessionManagerProvider);
      expect(state.sessions, isEmpty);
      expect(state.activeSessionId, isNull);
    });

    test('multiple sessions for same connection are supported', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      notifier.addSession(connectionId: 1, label: 'Server');
      notifier.addSession(connectionId: 1, label: 'Server');

      expect(container.read(sessionManagerProvider).sessions.length, 2);
    });

    test('removeSession preserves batteryWarning', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id1 = notifier.addSession(connectionId: 1, label: 'A');
      notifier.addSession(connectionId: 2, label: 'B');

      // Simulate battery warning being set (e.g. by _updateForegroundService).
      notifier.setBatteryWarningForTesting(true);
      expect(container.read(sessionManagerProvider).batteryWarning, isTrue);

      // Removing a session must not reset batteryWarning to false.
      notifier.removeSession(id1);

      expect(container.read(sessionManagerProvider).batteryWarning, isTrue);
    });

    test('removeSession preserves batteryWarning when last session removed', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id1 = notifier.addSession(connectionId: 1, label: 'A');
      notifier.setBatteryWarningForTesting(true);

      notifier.removeSession(id1);

      // batteryWarning remains true even after the last session is closed.
      final state = container.read(sessionManagerProvider);
      expect(state.sessions, isEmpty);
      expect(state.batteryWarning, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // reorderSessions() — ReorderableListView drag reorder
  // -------------------------------------------------------------------------

  group('reorderSessions()', () {
    // Helper: build a container with N plain sessions and return their IDs.
    List<String> _addSessions(
        SessionManagerNotifier notifier, int count) {
      return [
        for (var i = 1; i <= count; i++)
          notifier.addSession(connectionId: i, label: 'Server $i'),
      ];
    }

    test('moves first item to last position (forward move)', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);
      final ids = _addSessions(notifier, 3); // [A, B, C]

      // ReorderableListView passes newIndex=3 when dragging index 0 to the end.
      notifier.reorderSessions(0, 3);

      final sessions = container.read(sessionManagerProvider).sessions;
      expect(sessions.map((s) => s.sessionId).toList(),
          [ids[1], ids[2], ids[0]],
          reason: 'A moved to end → [B, C, A]');
    });

    test('moves last item to first position (backward move)', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);
      final ids = _addSessions(notifier, 3); // [A, B, C]

      notifier.reorderSessions(2, 0);

      final sessions = container.read(sessionManagerProvider).sessions;
      expect(sessions.map((s) => s.sessionId).toList(),
          [ids[2], ids[0], ids[1]],
          reason: 'C moved to front → [C, A, B]');
    });

    test('moves middle item to first position', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);
      final ids = _addSessions(notifier, 3); // [A, B, C]

      notifier.reorderSessions(1, 0);

      final sessions = container.read(sessionManagerProvider).sessions;
      expect(sessions.map((s) => s.sessionId).toList(),
          [ids[1], ids[0], ids[2]],
          reason: 'B moved to front → [B, A, C]');
    });

    test('moves first item to middle position (forward move)', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);
      final ids = _addSessions(notifier, 3); // [A, B, C]

      // newIndex=2 for forward move from index 0 to between B and C.
      notifier.reorderSessions(0, 2);

      final sessions = container.read(sessionManagerProvider).sessions;
      expect(sessions.map((s) => s.sessionId).toList(),
          [ids[1], ids[0], ids[2]],
          reason: 'A moved after B → [B, A, C]');
    });

    test('does not change activeSessionId after reorder', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);
      final ids = _addSessions(notifier, 3);
      // Last added is active.
      expect(container.read(sessionManagerProvider).activeSessionId, ids[2]);

      notifier.reorderSessions(0, 3); // move first to last

      expect(container.read(sessionManagerProvider).activeSessionId, ids[2],
          reason: 'reorder must not change which tab is active');
    });

    test('session count is unchanged after reorder', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);
      _addSessions(notifier, 4);

      notifier.reorderSessions(1, 3);

      expect(container.read(sessionManagerProvider).sessions.length, 4);
    });
  });

  group('tmux session helpers', () {
    test('addTmuxSession creates a session with tmuxSessionName', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id = notifier.addTmuxSession(
        connectionId: 1,
        tmuxSessionName: 'work',
      );

      final state = container.read(sessionManagerProvider);
      expect(state.sessions.length, 1);
      expect(state.sessions.first.sessionId, id);
      expect(state.sessions.first.tmuxSessionName, 'work');
      expect(state.sessions.first.label, 'tmux: work');
      expect(state.activeSessionId, id);
    });

    test('findSessionByTmux returns sessionId when found', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      final id = notifier.addTmuxSession(
        connectionId: 1,
        tmuxSessionName: 'work',
      );

      final found = notifier.findSessionByTmux(1, 'work');
      expect(found, id);
    });

    test('findSessionByTmux returns null when no match', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      notifier.addTmuxSession(connectionId: 1, tmuxSessionName: 'work');

      expect(notifier.findSessionByTmux(1, 'other'), isNull);
      expect(notifier.findSessionByTmux(2, 'work'), isNull);
    });

    test('findSessionByTmux does not match plain sessions without tmuxSessionName', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionManagerProvider.notifier);

      notifier.addSession(connectionId: 1, label: 'Server');

      expect(notifier.findSessionByTmux(1, 'work'), isNull);
    });
  });
}
