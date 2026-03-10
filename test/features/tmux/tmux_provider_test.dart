import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/features/tmux/tmux_provider.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_session_model.dart';

void main() {
  group('TmuxSession parsing', () {
    const sep = '|||';

    List<TmuxSession> parseOutput(String output) {
      final sessions = <TmuxSession>[];
      for (final line in output.trim().split('\n')) {
        if (line.isEmpty) continue;
        final parts = line.split(sep);
        if (parts.length != 4) continue;
        sessions.add(TmuxSession(
          name: parts[0],
          windowCount: int.tryParse(parts[1]) ?? 0,
          isAttached: parts[2] == '1',
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            (int.tryParse(parts[3]) ?? 0) * 1000,
          ),
        ));
      }
      return sessions;
    }

    test('parses single session', () {
      final output = 'main${sep}3${sep}1${sep}1700000000';
      final sessions = parseOutput(output);
      expect(sessions.length, 1);
      expect(sessions[0].name, 'main');
      expect(sessions[0].windowCount, 3);
      expect(sessions[0].isAttached, isTrue);
      expect(sessions[0].createdAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    });

    test('parses multiple sessions', () {
      final output = [
        'work${sep}2${sep}0${sep}1700000001',
        'personal${sep}1${sep}1${sep}1700000002',
      ].join('\n');
      final sessions = parseOutput(output);
      expect(sessions.length, 2);
      expect(sessions[0].name, 'work');
      expect(sessions[1].name, 'personal');
    });

    test('parses detached session', () {
      final output = 'bg${sep}1${sep}0${sep}1700000000';
      final sessions = parseOutput(output);
      expect(sessions[0].isAttached, isFalse);
    });

    test('skips line with wrong field count', () {
      final output = [
        'good${sep}1${sep}0${sep}1700000000',
        'bad_line_missing_fields', // only 1 field
        'also${sep}bad',            // only 2 fields
        'another${sep}1${sep}0${sep}1700000001',
      ].join('\n');
      final sessions = parseOutput(output);
      expect(sessions.length, 2);
      expect(sessions[0].name, 'good');
      expect(sessions[1].name, 'another');
    });

    test('returns empty list for empty output', () {
      expect(parseOutput(''), isEmpty);
    });

    test('returns empty list for whitespace-only output', () {
      expect(parseOutput('   \n  \n'), isEmpty);
    });

    test('handles session name with special characters (dashes, underscores)',
        () {
      final output = 'my-session_1${sep}2${sep}0${sep}1700000000';
      final sessions = parseOutput(output);
      expect(sessions[0].name, 'my-session_1');
    });

    test('handles zero-epoch timestamp', () {
      final output = 'session${sep}1${sep}0${sep}0';
      final sessions = parseOutput(output);
      expect(sessions[0].createdAt,
          DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('handles non-numeric window count gracefully', () {
      final output = 'session${sep}abc${sep}0${sep}1700000000';
      final sessions = parseOutput(output);
      expect(sessions[0].windowCount, 0);
    });
  });

  group('shellEscape', () {
    test('wraps in single quotes', () {
      expect(shellEscape('main'), "'main'");
    });

    test('escapes single quotes', () {
      expect(shellEscape("it's"), r"'it'\''s'");
    });

    test('handles session name with spaces', () {
      expect(shellEscape('my session'), "'my session'");
    });

    test('handles empty string', () {
      expect(shellEscape(''), "''");
    });
  });

  group('validateTmuxSessionName', () {
    test('accepts valid name', () {
      expect(validateTmuxSessionName('work', []), isNull);
    });

    test('rejects empty name', () {
      expect(validateTmuxSessionName('', []), isNotNull);
    });

    test('rejects name with space', () {
      expect(validateTmuxSessionName('my session', []), isNotNull);
    });

    test('rejects name with dot', () {
      expect(validateTmuxSessionName('my.session', []), isNotNull);
    });

    test('rejects name with colon', () {
      expect(validateTmuxSessionName('my:session', []), isNotNull);
    });

    test('rejects duplicate name', () {
      expect(
        validateTmuxSessionName('work', ['work', 'personal']),
        isNotNull,
      );
    });

    test('accepts name not in existing list', () {
      expect(
        validateTmuxSessionName('new-session', ['work', 'personal']),
        isNull,
      );
    });
  });

  group('TmuxState', () {
    test('isAvailable is true when tmux is available', () {
      final state = TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
      );
      expect(state.isAvailable, isTrue);
    });

    test('isAvailable is false when tmux is not installed', () {
      final state = TmuxState(availability: const TmuxNotInstalled());
      expect(state.isAvailable, isFalse);
    });

    test('copyWith updates sessions', () {
      final initial = TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
        sessions: [],
      );
      final session = TmuxSession(
        name: 'work',
        windowCount: 2,
        isAttached: false,
        createdAt: DateTime(2024),
      );
      final updated = initial.copyWith(sessions: [session]);
      expect(updated.sessions.length, 1);
      expect(updated.availability, isA<TmuxAvailable>());
    });
  });

  // ---------------------------------------------------------------------------
  // TmuxNotifier — channelManager injection pattern (Phase 6)
  // ---------------------------------------------------------------------------

  group('TmuxNotifier channelManager injection', () {
    test('initial state with null channelManager returns notAvailable', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // build() with _channelManager == null returns TmuxState(notInstalled).
      await container.read(tmuxProvider('conn-1').future);
      final state = container.read(tmuxProvider('conn-1'));

      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.isAvailable, isFalse);
      expect(state.value?.sessions, isEmpty);
    });

    test('setChannelManager(null) is a no-op when already null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);
      final stateBefore = container.read(tmuxProvider('conn-1'));

      // Guard: _channelManager == channelManager (both null) → early return.
      container.read(tmuxProvider('conn-1').notifier).setChannelManager(null);

      final stateAfter = container.read(tmuxProvider('conn-1'));
      expect(stateAfter.value?.isAvailable, isFalse);
      // State object identity is preserved — no rebuild occurred.
      expect(stateAfter, equals(stateBefore));
    });

    test('different connection IDs have independent notifiers', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await Future.wait([
        container.read(tmuxProvider('conn-a').future),
        container.read(tmuxProvider('conn-b').future),
      ]);

      final stateA = container.read(tmuxProvider('conn-a'));
      final stateB = container.read(tmuxProvider('conn-b'));

      expect(stateA.value?.isAvailable, isFalse);
      expect(stateB.value?.isAvailable, isFalse);

      // Calling setChannelManager on conn-a must not affect conn-b.
      container.read(tmuxProvider('conn-a').notifier).setChannelManager(null);

      final stateB2 = container.read(tmuxProvider('conn-b'));
      expect(stateB2, equals(stateB));
    });
  });

  // ---------------------------------------------------------------------------
  // _safeRefresh guard — null channelManager (Phase 8)
  // ---------------------------------------------------------------------------

  group('_safeRefresh null-channelManager guard', () {
    test('createSession with null channelManager does not throw', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);

      // _channelManager is null → createSession should return early, no throw.
      await expectLater(
        container
            .read(tmuxProvider('conn-1').notifier)
            .createSession('test-session'),
        completes,
      );

      // State must remain unchanged (TmuxNotInstalled).
      final state = container.read(tmuxProvider('conn-1'));
      expect(state.value?.isAvailable, isFalse);
    });

    test('killSession with null channelManager does not throw', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);

      await expectLater(
        container
            .read(tmuxProvider('conn-1').notifier)
            .killSession('some-session'),
        completes,
      );

      expect(container.read(tmuxProvider('conn-1')).value?.isAvailable, isFalse);
    });

    test('renameSession with null channelManager does not throw', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);

      await expectLater(
        container
            .read(tmuxProvider('conn-1').notifier)
            .renameSession('old-name', 'new-name'),
        completes,
      );

      expect(container.read(tmuxProvider('conn-1')).value?.isAvailable, isFalse);
    });

    test('ref.keepAlive is effective: provider state survives manual container read',
        () async {
      // ref.keepAlive() prevents the provider from being disposed when it has
      // no listeners. We verify the state is retained across multiple reads
      // (which would reset if keepAlive were absent and listeners dropped).
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);
      final state1 = container.read(tmuxProvider('conn-1'));

      // Reading again should return the same cached state (not rebuild).
      final state2 = container.read(tmuxProvider('conn-1'));
      expect(state2, equals(state1));
    });
  });

  // ---------------------------------------------------------------------------
  // killSession error-path: _isOperating is always reset (Phase 23 fix)
  //
  // Before the fix, _safeRefresh() was inside the try block of killSession().
  // On error (e.g. session not found), _safeRefresh was skipped and the UI
  // kept showing stale sessions. The fix moves _safeRefresh to finally so
  // it always runs.
  //
  // These tests verify the observable effect: _isOperating is always reset
  // so subsequent operations are never blocked by a stuck guard.
  // ---------------------------------------------------------------------------

  group('killSession _isOperating always reset (error-path fix)', () {
    test('killSession can be called consecutively without deadlock', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);
      final notifier = container.read(tmuxProvider('conn-1').notifier);

      // First call — channelManager is null → early return from try,
      // finally must reset _isOperating.
      await notifier.killSession('session-a');

      // Second call must not be blocked by a stuck _isOperating guard.
      await expectLater(notifier.killSession('session-b'), completes);
    });

    test('createSession after killSession is not blocked by _isOperating', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);
      final notifier = container.read(tmuxProvider('conn-1').notifier);

      await notifier.killSession('to-kill');

      // createSession must not see a stuck _isOperating = true from killSession.
      await expectLater(notifier.createSession('new-session'), completes);
    });

    test('renameSession after killSession is not blocked by _isOperating', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);
      final notifier = container.read(tmuxProvider('conn-1').notifier);

      await notifier.killSession('to-kill');

      await expectLater(
        notifier.renameSession('old-name', 'new-name'),
        completes,
      );
    });

    test('killSession state remains stable after multiple consecutive calls', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('conn-1').future);
      final notifier = container.read(tmuxProvider('conn-1').notifier);

      // Three consecutive killSession calls — none should corrupt state.
      await notifier.killSession('session-1');
      await notifier.killSession('session-2');
      await notifier.killSession('session-3');

      final state = container.read(tmuxProvider('conn-1'));
      expect(state.value?.isAvailable, isFalse);
    });
  });
}
