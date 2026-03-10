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
