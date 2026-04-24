import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:xterm/xterm.dart';

import 'package:terminal_ssh_app/core/ssh/ssh_channel_manager.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_provider.dart';
import 'package:terminal_ssh_app/features/tmux/tmux_session_model.dart';

// ---------------------------------------------------------------------------
// Mock helpers
// ---------------------------------------------------------------------------

/// Mock SshChannelManager for injecting channel-level failures into TmuxNotifier.
class _MockSshChannelManager extends Mock implements SshChannelManager {}

// ---------------------------------------------------------------------------
// Fake TerminalConnectionNotifier — used by attachSession() tests.
// ---------------------------------------------------------------------------

/// Module-level state injected into _FakeTerminalConnectionNotifier.
/// Set this before creating the container.
TerminalConnectionState _fakeConnState = const TerminalConnectionState();

/// Minimal override that returns _fakeConnState without running the real build().
/// Avoids SSH platform-channel calls while still satisfying ref.read() in
/// TmuxNotifier.attachSession().
class _FakeTerminalConnectionNotifier extends TerminalConnectionNotifier {
  @override
  TerminalConnectionState build(String arg) => _fakeConnState;
}

/// Mock SSHSession for stubbing stdout/stderr/done/exitCode without a real SSH server.
class _MockSSHSession extends Mock implements SSHSession {}

/// Builds a stubbed SSHSession with the given outputs.
/// Note: streams must use thenAnswer (not thenReturn) per mocktail's rules.
_MockSSHSession _makeSession({
  List<int> stdout = const [],
  List<int> stderr = const [],
  int? exitCode = 0,
}) {
  final s = _MockSSHSession();
  // Streams must use thenAnswer; thenReturn is disallowed for Stream types.
  when(() => s.stdout).thenAnswer(
    (_) => stdout.isEmpty
        ? const Stream<Uint8List>.empty()
        : Stream.value(Uint8List.fromList(stdout)),
  );
  when(() => s.stderr).thenAnswer(
    (_) => stderr.isEmpty
        ? const Stream<Uint8List>.empty()
        : Stream.value(Uint8List.fromList(stderr)),
  );
  when(() => s.done).thenAnswer((_) => Future<void>.value());
  when(() => s.exitCode).thenReturn(exitCode);
  when(() => s.close()).thenReturn(null);
  return s;
}

/// Returns a mock SshChannelManager that succeeds for ALL tmux commands.
/// 'command -v tmux' and 'tmux -V' return standard availability responses;
/// 'tmux list-sessions' returns one pre-canned session (name='work', windows=2,
/// attached=true, epoch=1700000000).  All other commands (e.g. set-option)
/// return exitCode 0.
///
/// IMPORTANT: sessions must be pre-created BEFORE registering the thenAnswer stub,
/// because calling when() inside a thenAnswer callback is forbidden by mocktail.
_MockSshChannelManager _makeFullSuccessManager() {
  final m = _MockSshChannelManager();

  const sep = '|||';
  final cmdVSession = _makeSession(exitCode: 0);
  final versionSession = _makeSession(
    stdout: utf8.encode('tmux 3.3a\n'),
    exitCode: null,
  );
  final listSession = _makeSession(
    stdout: utf8.encode('work${sep}2${sep}1${sep}1700000000\n'),
    exitCode: 0,
  );
  final noopSession = _makeSession(exitCode: 0);

  when(() => m.executeCommand(any())).thenAnswer((invocation) async {
    final cmd = invocation.positionalArguments[0] as String;
    if (cmd.contains('command -v')) return cmdVSession;
    if (cmd.contains('tmux -V')) return versionSession;
    if (cmd.contains('list-sessions')) return listSession;
    return noopSession;
  });
  return m;
}

/// Returns a mock SshChannelManager that:
///   • Succeeds for 'command -v tmux' (exitCode 0) and 'tmux -V' (version string)
///   • Throws for any list-sessions command (simulates network failure during fetch)
///
/// IMPORTANT: sessions must be pre-created BEFORE registering the thenAnswer stub,
/// because calling when() inside a thenAnswer callback is forbidden by mocktail.
_MockSshChannelManager _makePartialSuccessManager() {
  final m = _MockSshChannelManager();

  // Pre-create sessions outside the answer callback to avoid "Cannot call
  // when() within a stub response" errors.
  final cmdVSession = _makeSession(exitCode: 0);
  final versionSession = _makeSession(
    stdout: utf8.encode('tmux 3.3a\n'),
    exitCode: null, // dartssh2 may return null as success
  );

  when(() => m.executeCommand(any())).thenAnswer((invocation) async {
    final cmd = invocation.positionalArguments[0] as String;
    if (cmd.contains('command -v')) return cmdVSession;
    if (cmd.contains('tmux -V')) return versionSession;
    // list-sessions or any other command → throws (simulates network failure)
    throw Exception('network error during list-sessions');
  });
  return m;
}

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

    test('rejects name containing internal separator |||', () {
      // TmuxNotifier uses '|||' as field separator when parsing 'tmux list-sessions'
      // output. A session name containing this string would corrupt the parse,
      // silently skipping the session or misaligning fields.
      expect(validateTmuxSessionName('test|||session', []), isNotNull);
      expect(validateTmuxSessionName('|||', []), isNotNull);
      expect(validateTmuxSessionName('prefix|||', []), isNotNull);
    });

    test('accepts name with hyphens and underscores', () {
      // Common naming conventions for tmux sessions.
      expect(validateTmuxSessionName('my-project', []), isNull);
      expect(validateTmuxSessionName('my_project', []), isNull);
      expect(validateTmuxSessionName('project-2025_v2', []), isNull);
    });

    test('accepts name with numbers', () {
      expect(validateTmuxSessionName('session1', []), isNull);
      expect(validateTmuxSessionName('42', []), isNull);
    });

    test('two pipes || do not trigger separator rejection', () {
      // Only '|||' (three pipes) is the separator; '||' must be accepted.
      expect(validateTmuxSessionName('a||b', []), isNull);
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

    test('copyWith updates availability while preserving sessions', () {
      final session = TmuxSession(
        name: 'work',
        windowCount: 2,
        isAttached: false,
        createdAt: DateTime(2024),
      );
      final initial = TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
        sessions: [session],
      );
      final updated = initial.copyWith(availability: const TmuxNotInstalled());
      expect(updated.isAvailable, isFalse);
      expect(updated.sessions, [session]);
    });
  });

  // ---------------------------------------------------------------------------
  // TmuxSession model — equality, hashCode, toString (Phase 61)
  // ---------------------------------------------------------------------------

  group('TmuxSession model', () {
    final epoch = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);

    TmuxSession makeTs({
      String name = 'work',
      int windowCount = 3,
      bool isAttached = true,
    }) =>
        TmuxSession(
          name: name,
          windowCount: windowCount,
          isAttached: isAttached,
          createdAt: epoch,
        );

    test('== returns true for sessions with identical fields', () {
      expect(makeTs(), equals(makeTs()));
    });

    test('== returns false when name differs', () {
      expect(makeTs(name: 'work') == makeTs(name: 'personal'), isFalse);
    });

    test('== returns false when windowCount differs', () {
      expect(makeTs(windowCount: 2) == makeTs(windowCount: 5), isFalse);
    });

    test('== returns false when isAttached differs', () {
      expect(
        makeTs(isAttached: true) == makeTs(isAttached: false),
        isFalse,
      );
    });

    test('hashCode is consistent with equality', () {
      expect(makeTs().hashCode, equals(makeTs().hashCode));
    });

    test('hashCode differs for unequal sessions', () {
      // Different name → almost certainly different hash.
      expect(makeTs(name: 'work').hashCode == makeTs(name: 'other').hashCode,
          isFalse);
    });

    test('toString contains session name, windowCount and attached flag', () {
      final s = makeTs().toString();
      expect(s, contains('work'));
      expect(s, contains('3'));
      expect(s, contains('true'));
    });
  });

  // ---------------------------------------------------------------------------
  // _fetchSessions exit code != 0 paths (Phase 61)
  //
  // When tmux list-sessions exits with a non-zero code, _fetchSessions returns
  // an empty list rather than throwing.  The specific stderr message only
  // affects logging; all non-zero exit codes resolve to an empty session list
  // so the caller's state stays stable.
  // ---------------------------------------------------------------------------

  group('_fetchSessions exit code != 0 paths', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    /// Builds a mock manager whose list-sessions command exits with [exitCode]
    /// and writes [stderrMsg] to stderr, while availability checks succeed.
    _MockSshChannelManager makeListExitManager({
      required int exitCode,
      String stderrMsg = '',
    }) {
      final m = _MockSshChannelManager();
      final cmdVSession = _makeSession(exitCode: 0);
      final versionSession = _makeSession(
        stdout: utf8.encode('tmux 3.3a\n'),
        exitCode: null,
      );
      final listSession = _makeSession(
        exitCode: exitCode,
        stderr: utf8.encode(stderrMsg),
      );
      final noopSession = _makeSession(exitCode: 0);
      when(() => m.executeCommand(any())).thenAnswer((invocation) async {
        final cmd = invocation.positionalArguments[0] as String;
        if (cmd.contains('command -v')) return cmdVSession;
        if (cmd.contains('tmux -V')) return versionSession;
        if (cmd.contains('list-sessions')) return listSession;
        return noopSession;
      });
      return m;
    }

    Future<AsyncValue<TmuxState>> stateAfterInit(
        _MockSshChannelManager manager) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('fe-test').future);
      container.read(tmuxProvider('fe-test').notifier).setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return container.read(tmuxProvider('fe-test'));
    }

    test('"no server running" stderr → tmux available with empty sessions', () async {
      final m = makeListExitManager(
        exitCode: 1,
        stderrMsg:
            'error connecting to /tmp/tmux-1000/default (No server running on /tmp/tmux-1000/default)',
      );
      final state = await stateAfterInit(m);
      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.isAvailable, isTrue,
          reason: 'availability check succeeded; only list-sessions failed');
      expect(state.value?.sessions, isEmpty,
          reason: '"no server running" means 0 sessions');
    });

    test('"no sessions" stderr → tmux available with empty sessions', () async {
      final m = makeListExitManager(
        exitCode: 1,
        stderrMsg: 'no sessions',
      );
      final state = await stateAfterInit(m);
      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.isAvailable, isTrue);
      expect(state.value?.sessions, isEmpty);
    });

    test('other stderr → tmux available with empty sessions (no throw)', () async {
      final m = makeListExitManager(
        exitCode: 2,
        stderrMsg: 'unexpected error from tmux',
      );
      final state = await stateAfterInit(m);
      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.isAvailable, isTrue);
      expect(state.value?.sessions, isEmpty,
          reason: 'non-zero exit always resolves to empty session list');
    });
  });

  // ---------------------------------------------------------------------------
  // _fetchSessions malformed output path
  //
  // When list-sessions stdout contains lines with the wrong number of '|||'-
  // separated fields, _fetchSessions must skip those lines via the
  // `if (parts.length != 4) { ...; continue; }` guard and still parse the
  // valid lines.  The existing "TmuxSession parsing" group exercises this logic
  // via a local helper that never touches the real provider, leaving line 273
  // of tmux_provider.dart (the AppLogger.instance.log skip call) uncovered.
  // ---------------------------------------------------------------------------

  group('_fetchSessions malformed output — skips wrong-field-count lines', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    _MockSshChannelManager makeMalformedListManager(String listOutput) {
      final m = _MockSshChannelManager();
      final versionSession = _makeSession(
        stdout: utf8.encode('tmux 3.3a\n'),
        exitCode: null,
      );
      final listSession = _makeSession(
        stdout: utf8.encode(listOutput),
        exitCode: 0,
      );
      final noopSession = _makeSession(exitCode: 0);
      when(() => m.executeCommand(any())).thenAnswer((invocation) async {
        final cmd = invocation.positionalArguments[0] as String;
        if (cmd.contains('tmux -V')) return versionSession;
        if (cmd.contains('list-sessions')) return listSession;
        return noopSession;
      });
      return m;
    }

    Future<AsyncValue<TmuxState>> stateAfterInit(
        _MockSshChannelManager manager) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('malformed-test').future);
      container
          .read(tmuxProvider('malformed-test').notifier)
          .setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return container.read(tmuxProvider('malformed-test'));
    }

    test('skips lines with wrong field count and keeps valid ones', () async {
      const sep = '|||';
      // Two valid lines bookending two invalid ones.
      final output = [
        'valid${sep}3${sep}1${sep}1700000000',
        'only_one_field',
        'only${sep}two',
        'valid2${sep}1${sep}0${sep}1700000001',
      ].join('\n');

      final state = await stateAfterInit(makeMalformedListManager(output));

      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.isAvailable, isTrue);
      expect(state.value?.sessions.length, 2,
          reason: 'invalid-field-count lines must be skipped');
      expect(state.value?.sessions[0].name, 'valid');
      expect(state.value?.sessions[1].name, 'valid2');
    });

    test('returns empty sessions when all lines have wrong field count', () async {
      const sep = '|||';
      final output = [
        'no_sep',
        'a${sep}b',
        'a${sep}b${sep}c',
        'a${sep}b${sep}c${sep}d${sep}e', // 5 fields — too many
      ].join('\n');

      final state = await stateAfterInit(makeMalformedListManager(output));

      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.sessions, isEmpty,
          reason: 'no valid 4-field lines → empty session list');
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
  // _safeRefresh stale guard — Phase 53
  //
  // Bug fixed: _safeRefresh used `_channelManager != null` as its stale guard,
  // which allowed stale fetch results to overwrite state if the channelManager
  // was REPLACED (not just cleared) while _fetchSessions was in flight.
  // The fix uses `_channelManager == channelManager` (identity check), matching
  // the existing staleness guard pattern in _initializeState().
  // ---------------------------------------------------------------------------

  group('_safeRefresh stale guard', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    // When channelManager is replaced with a NEW manager while _safeRefresh
    // is awaiting _fetchSessions, the result must be discarded so it does not
    // overwrite the state that the new manager's _initializeState has already set.
    test(
        'does not overwrite new channelManager state when replaced mid-fetch',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Completer controls when m1's second list-sessions call (inside
      // _safeRefresh) resolves. This lets us inject a replacement channelManager
      // before _safeRefresh writes its result.
      final listBlockedCompleter = Completer<SSHSession>();
      var listCallCount = 0;

      // Build sessions outside thenAnswer to avoid mocktail restriction.
      final cmdVSess1 = _makeSession(exitCode: 0);
      final versionSess1 =
          _makeSession(stdout: utf8.encode('tmux 3.3a\n'), exitCode: null);
      final initListSess = _makeSession(
        stdout: utf8.encode('init-session|||1|||0|||1700000000\n'),
        exitCode: 0,
      );
      final newSessionSess = _makeSession(exitCode: 0);
      final noopSess1 = _makeSession(exitCode: 0);
      // The stale result that _safeRefresh would write without the guard fix.
      final staleListSess = _makeSession(
        stdout: utf8.encode('stale-session|||1|||0|||1700000000\n'),
        exitCode: 0,
      );

      final m1 = _MockSshChannelManager();
      when(() => m1.executeCommand(any())).thenAnswer((inv) {
        final cmd = inv.positionalArguments[0] as String;
        if (cmd.contains('command -v')) return Future.value(cmdVSess1);
        if (cmd.contains('tmux -V')) return Future.value(versionSess1);
        if (cmd.contains('list-sessions')) {
          listCallCount++;
          // First call (from _initializeState): return immediately.
          if (listCallCount == 1) return Future.value(initListSess);
          // Second call (from _safeRefresh): block until released.
          listBlockedCompleter.complete(staleListSess);
          return listBlockedCompleter.future;
        }
        if (cmd.contains('new-session')) return Future.value(newSessionSess);
        return Future.value(noopSess1);
      });

      // m2: a fresh manager that returns the 'work' session.
      final m2 = _makeFullSuccessManager();

      // 1. Initialize provider (no SSH calls — channelManager is null).
      await container.read(tmuxProvider('sr-stale').future);
      final notifier = container.read(tmuxProvider('sr-stale').notifier);

      // 2. Inject m1 → _initializeState runs, list-sessions returns immediately.
      notifier.setChannelManager(m1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Sanity: state should now have 'init-session'.
      expect(
        container.read(tmuxProvider('sr-stale')).value?.sessions
            .map((s) => s.name),
        contains('init-session'),
        reason: 'setup: m1 _initializeState must have set init-session',
      );

      // 3. Call createSession — new-session succeeds, then _safeRefresh starts
      //    and blocks on list-sessions (listCallCount == 2).
      final createFuture = notifier.createSession('new-session');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // 4. Replace channelManager with m2 while _safeRefresh is blocked.
      //    setChannelManager triggers _initializeState(m2) which will set 'work'.
      notifier.setChannelManager(m2);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // m2's _initializeState should have completed with 'work'.
      expect(
        container.read(tmuxProvider('sr-stale')).value?.sessions
            .map((s) => s.name),
        contains('work'),
        reason: 'm2 _initializeState must have set work session',
      );

      // 5. Release the blocked _safeRefresh.  With the fix (_channelManager ==
      //    channelManager identity check), m1's stale result must be discarded.
      await createFuture;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final finalState = container.read(tmuxProvider('sr-stale'));
      expect(
        finalState.value?.sessions.map((s) => s.name),
        contains('work'),
        reason: 'stale _safeRefresh must not replace state set by new channelManager',
      );
      expect(
        finalState.value?.sessions.map((s) => s.name),
        isNot(contains('stale-session')),
        reason: 'stale-session from m1 _safeRefresh must not appear in final state',
      );
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

  // ---------------------------------------------------------------------------
  // startAutoRefresh / stopAutoRefresh — timer lifecycle
  //
  // startAutoRefresh はドロワーが開いたときに定期リフレッシュを開始し、
  // stopAutoRefresh はドロワーが閉じたときにタイマーをキャンセルする。
  // チャンネルマネージャが null の場合、タイマー発火時の refresh() は
  // 早期リターンするため state は変化しない（クラッシュしない）。
  // ---------------------------------------------------------------------------

  group('startAutoRefresh / stopAutoRefresh', () {
    test('startAutoRefresh does not throw when channelManager is null',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('refresh-1').future);
      final notifier = container.read(tmuxProvider('refresh-1').notifier);

      expect(() => notifier.startAutoRefresh(), returnsNormally);
      notifier.stopAutoRefresh(); // clean up timer
    });

    test('stopAutoRefresh is safe to call before startAutoRefresh', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('refresh-2').future);
      final notifier = container.read(tmuxProvider('refresh-2').notifier);

      // Calling stop before start must not throw.
      expect(() => notifier.stopAutoRefresh(), returnsNormally);
    });

    test('startAutoRefresh called twice replaces previous timer without error',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('refresh-3').future);
      final notifier = container.read(tmuxProvider('refresh-3').notifier);

      notifier.startAutoRefresh();
      // Second call must cancel the first timer and install a new one.
      expect(() => notifier.startAutoRefresh(), returnsNormally);
      notifier.stopAutoRefresh();
    });

    test('stopAutoRefresh after startAutoRefresh cancels the timer', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('refresh-4').future);
      final notifier = container.read(tmuxProvider('refresh-4').notifier);

      notifier.startAutoRefresh();
      // Stopping immediately should not throw and should cancel the timer.
      expect(() => notifier.stopAutoRefresh(), returnsNormally);

      // Subsequent stop is also safe (idempotent).
      expect(() => notifier.stopAutoRefresh(), returnsNormally);
    });

    test('provider dispose cancels refresh timer without error', () async {
      final container = ProviderContainer();
      // Do NOT add tearDown here — we dispose manually below.

      await container.read(tmuxProvider('refresh-5').future);
      final notifier = container.read(tmuxProvider('refresh-5').notifier);

      notifier.startAutoRefresh();
      // Disposing the container triggers ref.onDispose which cancels the timer.
      expect(() => container.dispose(), returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  // _initializeState() — error recovery (Phase 47)
  //
  // _initializeState は 2 段階で SSH コマンドを実行する:
  //   1. _checkAvailability: 'command -v tmux' + 'tmux -V'
  //   2. _fetchSessions:     'tmux list-sessions ...'
  //
  // エラーの発生場所によって挙動が異なる:
  //   • _checkAvailability 内エラー: _checkAvailability が内部で catch し
  //     TmuxNotInstalled を返す → state = TmuxNotInstalled（前回データは置換される）
  //   • _fetchSessions 内エラー: _initializeState の catch が受け取り
  //     prev != null のとき前回データを維持する（再接続時に UI が壊れない）
  // ---------------------------------------------------------------------------

  group('_initializeState() error recovery', () {
    setUpAll(() {
      // mocktail requires fallback values for matchers that use any().
      registerFallbackValue('');
    });

    // _checkAvailability は自前の try-catch を持ち、エラー時に TmuxNotInstalled を返す。
    // その結果 _initializeState は state = TmuxNotInstalled に遷移する（AsyncError にはならない）。
    test(
        'executeCommand throws → _checkAvailability gracefully returns '
        'TmuxNotInstalled (no AsyncError)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('ei-test-1').future);
      final notifier = container.read(tmuxProvider('ei-test-1').notifier);

      final throwing = _MockSshChannelManager();
      when(() => throwing.executeCommand(any()))
          .thenThrow(Exception('SSH channel error'));
      notifier.setChannelManager(throwing);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(tmuxProvider('ei-test-1'));
      expect(state, isA<AsyncData<TmuxState>>(),
          reason: '_initializeState must never emit AsyncError');
      expect(state.value?.isAvailable, isFalse,
          reason: '_checkAvailability catches error and returns TmuxNotInstalled');
    });

    // _fetchSessions は try-catch を持たないため、そのエラーは _initializeState の
    // catch へ伝播する。prev != null のとき前回データが維持される。
    test(
        '_fetchSessions throws → _initializeState catch preserves rich '
        'previous state', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('ei-test-2').future);
      final notifier = container.read(tmuxProvider('ei-test-2').notifier);

      // Set up a rich previous state (TmuxAvailable + 1 session).
      final richState = TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
        sessions: [
          TmuxSession(
            name: 'work',
            windowCount: 3,
            isAttached: true,
            createdAt: DateTime(2024),
          ),
        ],
      );
      notifier.setStateForTesting(richState);

      // Manager succeeds for availability check but throws for list-sessions.
      notifier.setChannelManager(_makePartialSuccessManager());

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(tmuxProvider('ei-test-2'));
      expect(state, isA<AsyncData<TmuxState>>(),
          reason: 'must stay AsyncData, never transition to AsyncError');
      expect(state.value?.isAvailable, isTrue,
          reason: 'TmuxAvailable must survive a _fetchSessions error');
      expect(state.value?.sessions.length, 1,
          reason: 'previous session list must not be wiped by the error');
      expect(state.value?.sessions.first.name, 'work');
    });

    // prev != null のとき、_initializeState は state = AsyncLoading を発行しない。
    // これにより再接続エラー時にローディングスピナーが点滅しない。
    test(
        '_fetchSessions throws with known prev state → no AsyncLoading emitted',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('ei-test-3').future);
      final notifier = container.read(tmuxProvider('ei-test-3').notifier);

      notifier.setStateForTesting(TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.2'),
        sessions: [],
      ));

      var seenLoading = false;
      container.listen(tmuxProvider('ei-test-3'), (_, next) {
        if (next is AsyncLoading) seenLoading = true;
      });

      notifier.setChannelManager(_makePartialSuccessManager());

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(seenLoading, isFalse,
          reason:
              'no AsyncLoading must be emitted when prev state is available');
    });
  });

  // ---------------------------------------------------------------------------
  // _initializeState() — staleness guard (Phase 48)
  //
  // setChannelManager(null) を呼び出した後、実行中の _initializeState が
  // prev(TmuxAvailable) を state に復元してしまう race condition を防ぐ。
  //
  // Guard: _checkAvailability / _fetchSessions の await 後に
  //   if (_channelManager != channelManager) return;
  // を挿入し、stale な場合は state 更新を中断する。
  // ---------------------------------------------------------------------------

  group('_initializeState() staleness guard', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    // setChannelManager(null) は同期的に state = TmuxNotInstalled をセットする。
    // その後 _initializeState が完了しても state が上書きされないことを検証する。
    test(
        'setChannelManager(null) during _initializeState prevents stale '
        'TmuxAvailable from being restored', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('sg-test-1').future);
      final notifier = container.read(tmuxProvider('sg-test-1').notifier);

      // Set a rich previous state (TmuxAvailable + 1 session).
      notifier.setStateForTesting(TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
        sessions: [
          TmuxSession(
            name: 'work',
            windowCount: 2,
            isAttached: true,
            createdAt: DateTime(2024),
          ),
        ],
      ));

      // _makePartialSuccessManager succeeds availability check but throws for
      // list-sessions. Without the staleness guard the catch block would restore
      // prev (TmuxAvailable) after setChannelManager(null) set TmuxNotInstalled.
      notifier.setChannelManager(_makePartialSuccessManager());

      // Immediately clear the channel — simulates SSH disconnect.
      notifier.setChannelManager(null);

      // Verify synchronous reset is already in effect.
      final stateSync = container.read(tmuxProvider('sg-test-1'));
      expect(stateSync.value?.isAvailable, isFalse,
          reason:
              'setChannelManager(null) must synchronously set TmuxNotInstalled');

      // Wait for any pending _initializeState work to complete.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final stateAsync = container.read(tmuxProvider('sg-test-1'));
      expect(stateAsync, isA<AsyncData<TmuxState>>(),
          reason: 'state must stay AsyncData, never AsyncError');
      expect(stateAsync.value?.isAvailable, isFalse,
          reason:
              'stale _initializeState must not restore TmuxAvailable after channel cleared');
      expect(stateAsync.value?.sessions, isEmpty);
    });

    // null → non-null → null の連続遷移でも最終 state は TmuxNotInstalled。
    test(
        'setChannelManager(null) resets state regardless of '
        '_initializeState background work',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('sg-test-2').future);
      final notifier = container.read(tmuxProvider('sg-test-2').notifier);

      // Use a throwing manager — _checkAvailability catches and returns TmuxNotInstalled.
      final m = _MockSshChannelManager();
      when(() => m.executeCommand(any())).thenThrow(Exception('channel error'));

      notifier.setChannelManager(m);    // starts _initializeState (async)
      notifier.setChannelManager(null); // synchronous reset

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(tmuxProvider('sg-test-2'));
      expect(state.value?.isAvailable, isFalse);
      expect(state.value?.sessions, isEmpty);
    });

    // _initializeState line-47 stale guard: _checkAvailability succeeds AND
    // _fetchSessions also succeeds, but the channel was replaced before
    // _fetchSessions returned.  The result must be discarded.
    //
    // This path differs from the existing tests which either:
    //   (a) use _makePartialSuccessManager (throws in _fetchSessions → catch stale check)
    //   (b) have the channel cleared before _checkAvailability even completes.
    // Here the channel is replaced WHILE _fetchSessions is awaiting, and
    // _fetchSessions eventually succeeds.  Line 47 must discard that result.
    test(
        'channel replaced during _fetchSessions: line-47 stale guard '
        'prevents m1 result overwriting m2 state', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('sg-test-3').future);
      final notifier = container.read(tmuxProvider('sg-test-3').notifier);

      // Completer controls when m1's list-sessions call resolves.
      final listCompleter = Completer<SSHSession>();

      // m1 pre-created sessions (outside answer to satisfy mocktail constraints).
      final m1CmdV   = _makeSession(exitCode: 0);
      final m1Ver    = _makeSession(stdout: utf8.encode('tmux 3.3a\n'), exitCode: null);
      final m1List   = _makeSession(
        stdout: utf8.encode('m1-session|||1|||0|||1700000000\n'),
        exitCode: 0,
      );

      final m1 = _MockSshChannelManager();
      when(() => m1.executeCommand(any())).thenAnswer((inv) {
        final cmd = inv.positionalArguments[0] as String;
        if (cmd.contains('command -v')) return Future.value(m1CmdV);
        if (cmd.contains('tmux -V'))    return Future.value(m1Ver);
        if (cmd.contains('list-sessions')) {
          // Block until the completer is resolved.
          listCompleter.complete(m1List);
          return listCompleter.future;
        }
        return Future.value(_makeSession(exitCode: 0));
      });

      // m2 succeeds immediately with 'work' session.
      final m2 = _makeFullSuccessManager();

      // 1. Start _initializeState(m1) — _checkAvailability completes sync-ish,
      //    then _fetchSessions blocks on the Completer.
      notifier.setChannelManager(m1);
      // Give _checkAvailability time to complete before replacing.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 2. Replace with m2 while m1's _fetchSessions is still awaiting.
      //    _initializeState(m2) runs and should complete quickly.
      notifier.setChannelManager(m2);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // m2's _initializeState must have set 'work'.
      expect(
        container.read(tmuxProvider('sg-test-3')).value?.sessions
            .map((s) => s.name),
        contains('work'),
        reason: 'm2 _initializeState must set state to work session',
      );

      // 3. Allow m1's _fetchSessions to resolve (Completer already completed above).
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 4. Line-47 stale guard must have discarded m1's result.
      final finalState = container.read(tmuxProvider('sg-test-3'));
      expect(
        finalState.value?.sessions.map((s) => s.name),
        contains('work'),
        reason: 'line-47 stale guard must keep m2 state',
      );
      expect(
        finalState.value?.sessions.map((s) => s.name),
        isNot(contains('m1-session')),
        reason: 'stale m1 _fetchSessions result must not appear after m2 set state',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // refresh() — three main paths (Phase 49)
  //
  // refresh() has three paths:
  //   1. null channelManager  → returns early, state unchanged
  //   2. success              → sessions list updated from SSH
  //   3. _fetchSessions error → existing state preserved (no AsyncError)
  // ---------------------------------------------------------------------------

  group('refresh()', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    // Path 1: channelManager is null → early return, state unchanged.
    test('returns early when channelManager is null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('rp-null').future);
      final notifier = container.read(tmuxProvider('rp-null').notifier);

      // No setChannelManager() called → _channelManager is null.
      await notifier.refresh();

      final state = container.read(tmuxProvider('rp-null'));
      expect(state.value?.isAvailable, isFalse,
          reason: 'null channelManager guard must leave state unchanged');
    });

    // Path 2: success — sessions list is fetched and state is updated.
    test('updates sessions list on success', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('rp-success').future);
      final notifier = container.read(tmuxProvider('rp-success').notifier);

      // setChannelManager triggers _initializeState which populates 1 session.
      notifier.setChannelManager(_makeFullSuccessManager());
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Confirm init succeeded.
      final afterInit = container.read(tmuxProvider('rp-success'));
      expect(afterInit.value?.isAvailable, isTrue);
      expect(afterInit.value?.sessions.length, 1);
      expect(afterInit.value?.sessions.first.name, 'work');

      // refresh() re-fetches and the same session data is still present.
      await notifier.refresh();

      final afterRefresh = container.read(tmuxProvider('rp-success'));
      expect(afterRefresh, isA<AsyncData<TmuxState>>());
      expect(afterRefresh.value?.isAvailable, isTrue);
      expect(afterRefresh.value?.sessions.length, 1);
      expect(afterRefresh.value?.sessions.first.name, 'work',
          reason: 'session name must survive the refresh() cycle');
    });

    // Path 3: _fetchSessions throws during refresh() → state is preserved.
    test('preserves existing state when _fetchSessions throws', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('rp-error').future);
      final notifier = container.read(tmuxProvider('rp-error').notifier);

      // Plant a rich previous state so there is something worth preserving.
      final richState = TmuxState(
        availability: const TmuxAvailable(version: 'tmux 3.3a'),
        sessions: [
          TmuxSession(
            name: 'preserved',
            windowCount: 1,
            isAttached: false,
            createdAt: DateTime(2024),
          ),
        ],
      );
      notifier.setStateForTesting(richState);

      // Use a partial-success manager: availability succeeds, list-sessions throws.
      // _initializeState will also fail and restore the rich state (prev != null).
      notifier.setChannelManager(_makePartialSuccessManager());
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The channelManager is set (non-null), so refresh() proceeds to _fetchSessions.
      // _fetchSessions will throw again → catch block restores current state.
      await notifier.refresh();

      final state = container.read(tmuxProvider('rp-error'));
      expect(state, isA<AsyncData<TmuxState>>(),
          reason: 'refresh() must not emit AsyncError even when fetch fails');
      expect(state.value?.isAvailable, isTrue,
          reason: 'TmuxAvailable must be preserved after a failed refresh()');
      expect(state.value?.sessions.first.name, 'preserved',
          reason: 'session list from before the failed refresh must survive');
    });
  });

  // ---------------------------------------------------------------------------
  // createSession() — normal path (Phase 51)
  //
  // createSession() calls two exec commands:
  //   1. 'tmux new-session -d -s <escaped>'
  //   2. 'tmux set-option -t <escaped> mouse on'  (fire-and-forget)
  // Then _safeRefresh() fetches the updated session list.
  // ---------------------------------------------------------------------------

  group('createSession() normal path', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('sends new-session command with shell-escaped name', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('cs-normal').future);
      final notifier = container.read(tmuxProvider('cs-normal').notifier);

      final manager = _makeFullSuccessManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.createSession('work');

      verify(() => manager.executeCommand("tmux new-session -d -s 'work'"))
          .called(1);
    });

    test('enables mouse mode after creating session', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('cs-mouse').future);
      final notifier = container.read(tmuxProvider('cs-mouse').notifier);

      final manager = _makeFullSuccessManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.createSession('work');

      verify(() => manager.executeCommand("tmux set-option -t 'work' mouse on"))
          .called(1);
    });

    test('shell-escapes session name containing single quotes', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('cs-quote').future);
      final notifier = container.read(tmuxProvider('cs-quote').notifier);

      final manager = _makeFullSuccessManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // shellEscape("it's") = "'it'\\''s'"
      await notifier.createSession("it's");

      verify(() => manager.executeCommand(
        r"tmux new-session -d -s 'it'\''s'",
      )).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // killSession() — normal path (Phase 51)
  //
  // killSession() sends 'tmux kill-session -t <escaped>' then _safeRefresh().
  // ---------------------------------------------------------------------------

  group('killSession() normal path', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('sends kill-session command with shell-escaped name', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('ks-normal').future);
      final notifier = container.read(tmuxProvider('ks-normal').notifier);

      final manager = _makeFullSuccessManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.killSession('work');

      verify(() => manager.executeCommand("tmux kill-session -t 'work'"))
          .called(1);
    });

    test('shell-escapes session name with special characters', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('ks-esc').future);
      final notifier = container.read(tmuxProvider('ks-esc').notifier);

      final manager = _makeFullSuccessManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.killSession('my-session');

      verify(() => manager.executeCommand("tmux kill-session -t 'my-session'"))
          .called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // renameSession() — normal path (Phase 52)
  //
  // renameSession() calls:
  //   'tmux rename-session -t <escapedOld> <escapedNew>'
  // Then _safeRefresh() fetches the updated session list.
  // ---------------------------------------------------------------------------

  group('renameSession() normal path', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('sends rename-session command with shell-escaped names', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('rs-normal').future);
      final notifier = container.read(tmuxProvider('rs-normal').notifier);

      final manager = _makeFullSuccessManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.renameSession('work', 'dev');

      verify(() => manager.executeCommand("tmux rename-session -t 'work' 'dev'"))
          .called(1);
    });

    test('shell-escapes old name containing single quotes', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('rs-quote-old').future);
      final notifier = container.read(tmuxProvider('rs-quote-old').notifier);

      final manager = _makeFullSuccessManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // shellEscape("it's") = "'it'\\''s'"
      await notifier.renameSession("it's", 'dev');

      verify(() => manager.executeCommand(
        r"tmux rename-session -t 'it'\''s' 'dev'",
      )).called(1);
    });

    test('shell-escapes new name containing single quotes', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('rs-quote-new').future);
      final notifier = container.read(tmuxProvider('rs-quote-new').notifier);

      final manager = _makeFullSuccessManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // shellEscape("it's") = "'it'\\''s'"
      await notifier.renameSession('work', "it's");

      verify(() => manager.executeCommand(
        r"tmux rename-session -t 'work' 'it'\''s'",
      )).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // renameSession() — error path (Phase 58)
  //
  // renameSession() must swallow errors from _execCommand (e.g. session not
  // found, name already taken) in the same way killSession() does.
  // Before this fix, a TmuxError propagated out of renameSession(), which
  // would crash any UI caller that didn't wrap it in try/catch.
  // ---------------------------------------------------------------------------

  group('renameSession() error path', () {
    /// Returns a manager that fails (exit=1) specifically for rename-session
    /// commands, while succeeding for availability checks and list-sessions
    /// so that initialization and _safeRefresh() work normally.
    _MockSshChannelManager makeRenameFailManager() {
      final m = _MockSshChannelManager();

      const sep = '|||';
      final cmdVSession = _makeSession(exitCode: 0);
      final versionSession = _makeSession(
        stdout: utf8.encode('tmux 3.3a\n'),
        exitCode: null,
      );
      final listSession = _makeSession(
        stdout: utf8.encode('work${sep}2${sep}1${sep}1700000000\n'),
        exitCode: 0,
      );
      // rename-session returns exit code 1 (e.g. name collision or no such session)
      final failSession = _makeSession(exitCode: 1);

      when(() => m.executeCommand(any())).thenAnswer((invocation) async {
        final cmd = invocation.positionalArguments[0] as String;
        if (cmd.contains('command -v')) return cmdVSession;
        if (cmd.contains('tmux -V')) return versionSession;
        if (cmd.contains('list-sessions')) return listSession;
        if (cmd.contains('rename-session')) return failSession;
        return _makeSession(exitCode: 0);
      });
      return m;
    }

    test('completes without throwing when command exits non-zero', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('rs-err-nothrow').future);
      final notifier = container.read(tmuxProvider('rs-err-nothrow').notifier);

      final manager = makeRenameFailManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Must not throw — matches killSession() behaviour.
      await expectLater(
        notifier.renameSession('old-name', 'new-name'),
        completes,
      );
    });

    test('_isOperating is reset after failed rename so next op is not blocked',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('rs-err-guard').future);
      final notifier = container.read(tmuxProvider('rs-err-guard').notifier);

      final manager = makeRenameFailManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.renameSession('old-name', 'new-name');

      // A subsequent renameSession must not be blocked by a stuck _isOperating.
      await expectLater(
        notifier.renameSession('old-name', 'new-name-2'),
        completes,
      );
    });

    test('_safeRefresh runs after failed rename (state stays consistent)',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(tmuxProvider('rs-err-refresh').future);
      final notifier = container.read(tmuxProvider('rs-err-refresh').notifier);

      final manager = makeRenameFailManager();
      notifier.setChannelManager(manager);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.renameSession('old-name', 'new-name');

      // _safeRefresh should have triggered another list-sessions call; the
      // state must remain a valid TmuxState (not error) after the failed rename.
      final state = container.read(tmuxProvider('rs-err-refresh'));
      expect(state.hasValue, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // attachSession() — Phase 50
  //
  // attachSession() reads terminalConnectionProvider(arg) to get the PTY
  // Terminal, then calls terminal.textInput('tmux attach -t <name>\r').
  //
  // Paths:
  //   1. terminal == null → early return, no textInput
  //   2. terminal != null → textInput with shell-escaped session name
  // ---------------------------------------------------------------------------

  group('attachSession()', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    // Path 1: no terminal in connection state → attachSession is a no-op.
    test('does nothing when terminal is null', () async {
      _fakeConnState = const TerminalConnectionState(
        status: ConnectionStatus.disconnected,
        // terminal is null by default
      );
      final container = ProviderContainer(
        overrides: [
          terminalConnectionProvider.overrideWith(
            _FakeTerminalConnectionNotifier.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(tmuxProvider('as-null').future);
      final notifier = container.read(tmuxProvider('as-null').notifier);

      // Provide a channel manager so the notifier is "ready".
      notifier.setChannelManager(_makeFullSuccessManager());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Should return early without throwing.
      expect(
        () => notifier.attachSession('work'),
        returnsNormally,
      );
    });

    // Path 2: terminal present → textInput writes the attach command.
    test('sends tmux attach command to the terminal', () async {
      final terminal = Terminal(maxLines: 1000);
      final received = <String>[];
      terminal.onOutput = received.add;

      _fakeConnState = TerminalConnectionState(
        status: ConnectionStatus.connected,
        terminal: terminal,
      );
      final container = ProviderContainer(
        overrides: [
          terminalConnectionProvider.overrideWith(
            _FakeTerminalConnectionNotifier.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(tmuxProvider('as-term').future);
      final notifier = container.read(tmuxProvider('as-term').notifier);
      notifier.setChannelManager(_makeFullSuccessManager());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      notifier.attachSession('my-session');

      // terminal.textInput outputs the command directly (synchronous).
      final combined = received.join('');
      expect(combined, contains("tmux attach -t 'my-session'\r"),
          reason: 'attachSession must write the shell-quoted attach command');
    });

    // Path 2b: session name with special characters is shell-escaped.
    test('shell-escapes session names with spaces', () async {
      final terminal = Terminal(maxLines: 1000);
      final received = <String>[];
      terminal.onOutput = received.add;

      _fakeConnState = TerminalConnectionState(
        status: ConnectionStatus.connected,
        terminal: terminal,
      );
      final container = ProviderContainer(
        overrides: [
          terminalConnectionProvider.overrideWith(
            _FakeTerminalConnectionNotifier.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(tmuxProvider('as-escape').future);
      final notifier = container.read(tmuxProvider('as-escape').notifier);
      notifier.setChannelManager(_makeFullSuccessManager());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // shellEscape("my session") = "'my session'"
      notifier.attachSession('my session');

      final combined = received.join('');
      expect(combined, contains("tmux attach -t 'my session'\r"));
    });
  });

  // ---------------------------------------------------------------------------
  // setChannelManager() while _isOperating == true — Phase 54
  //
  // When setChannelManager(m2) is called while createSession / killSession /
  // renameSession is in flight (_isOperating == true), _initializeState(m2)
  // must NOT be triggered.  The new manager is stored but initialisation is
  // deferred: after the operation completes its finally-block resets
  // _isOperating and calls _safeRefresh(), which uses the new manager.
  //
  // Observable invariant:
  //   • During the operation window: state still reflects m1 (no 'work' yet).
  //   • After the operation: _safeRefresh(m2) updates sessions to 'work'.
  //   • Availability from m1's _initializeState is preserved via copyWith.
  // ---------------------------------------------------------------------------

  group('setChannelManager() while _isOperating skips _initializeState', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test(
        'setChannelManager during createSession does not trigger '
        '_initializeState; _safeRefresh picks up new manager after op',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Completer controls when m1's new-session command resolves.
      // Until it resolves the createSession coroutine is suspended inside the
      // try block, keeping _isOperating == true.
      final newSessionCompleter = Completer<SSHSession>();

      // Pre-create all sessions outside thenAnswer (mocktail restriction).
      final m1CmdV = _makeSession(exitCode: 0);
      final m1Ver = _makeSession(
        stdout: utf8.encode('tmux 3.3a\n'),
        exitCode: null,
      );
      final m1InitList = _makeSession(
        stdout: utf8.encode('init-session|||1|||0|||1700000000\n'),
        exitCode: 0,
      );
      final m1NewSession = _makeSession(exitCode: 0);
      final m1Noop = _makeSession(exitCode: 0);

      final m1 = _MockSshChannelManager();
      when(() => m1.executeCommand(any())).thenAnswer((inv) {
        final cmd = inv.positionalArguments[0] as String;
        if (cmd.contains('command -v')) return Future.value(m1CmdV);
        if (cmd.contains('tmux -V')) return Future.value(m1Ver);
        if (cmd.contains('list-sessions')) return Future.value(m1InitList);
        if (cmd.contains('new-session')) {
          // Block until explicitly released — holds _isOperating == true.
          return newSessionCompleter.future;
        }
        // set-option and any other commands succeed immediately.
        return Future.value(m1Noop);
      });

      // m2 returns 'work' session immediately for all commands.
      final m2 = _makeFullSuccessManager();

      // 1. Initialize provider and inject m1.
      await container.read(tmuxProvider('oi-1').future);
      final notifier = container.read(tmuxProvider('oi-1').notifier);
      notifier.setChannelManager(m1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Sanity: m1's _initializeState must have set 'init-session'.
      expect(
        container.read(tmuxProvider('oi-1')).value?.sessions.map((s) => s.name),
        contains('init-session'),
        reason: 'setup: m1 _initializeState must populate init-session',
      );

      // 2. Start createSession — new-session command blocks on the Completer.
      //    _isOperating is now true (inside the try block).
      final createFuture = notifier.createSession('blocked-session');
      // Give the async machinery enough time to reach the awaiting point.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 3. Replace channelManager with m2 while _isOperating == true.
      //    _initializeState(m2) must NOT be called.
      notifier.setChannelManager(m2);

      // 4. Wait long enough for _initializeState(m2) to have completed IF
      //    it were incorrectly triggered (m2 is instantaneous).
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 'work' must NOT appear yet — _initializeState(m2) was skipped.
      final stateDuringOp = container.read(tmuxProvider('oi-1'));
      expect(
        stateDuringOp.value?.sessions.map((s) => s.name),
        isNot(contains('work')),
        reason:
            '_initializeState(m2) must not run while _isOperating == true',
      );
      expect(
        stateDuringOp.value?.sessions.map((s) => s.name),
        contains('init-session'),
        reason: 'state must still reflect m1 init result during the lock',
      );

      // 5. Release the blocked new-session.
      //    createSession finally: _isOperating = false → _safeRefresh(m2).
      newSessionCompleter.complete(m1NewSession);
      await createFuture; // _safeRefresh is awaited inside createSession

      // 6. _safeRefresh(m2) must have updated sessions to 'work'.
      final finalState = container.read(tmuxProvider('oi-1'));
      expect(
        finalState.value?.sessions.map((s) => s.name),
        contains('work'),
        reason: '_safeRefresh must use m2 channelManager after operation',
      );
      expect(
        finalState.value?.isAvailable,
        isTrue,
        reason: 'TmuxAvailable from m1 _initializeState must be preserved',
      );
      expect(finalState, isA<AsyncData<TmuxState>>());
    });
  });

  // ---------------------------------------------------------------------------
  // setChannelManager() identical-manager guard — Phase 62
  //
  // setChannelManager() returns early when the new channelManager is the same
  // object reference as the current one (_channelManager == channelManager).
  // This prevents a redundant _initializeState() call and avoids flickering.
  // ---------------------------------------------------------------------------

  group('setChannelManager() identical-manager guard', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('calling setChannelManager twice with same non-null manager is a no-op',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('idem-1').future);
      final notifier = container.read(tmuxProvider('idem-1').notifier);

      final m = _makeFullSuccessManager();
      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final stateAfterFirst = container.read(tmuxProvider('idem-1'));
      expect(stateAfterFirst.value?.isAvailable, isTrue);
      expect(stateAfterFirst.value?.sessions.length, 1);

      // Second call with the IDENTICAL manager instance.
      // The identical guard (_channelManager == channelManager) fires →
      // _initializeState is NOT triggered a second time.
      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final stateAfterSecond = container.read(tmuxProvider('idem-1'));
      expect(stateAfterSecond.value?.sessions.length, 1,
          reason: 'identical manager guard prevents double-initialization');
      expect(stateAfterSecond.value?.sessions.first.name, 'work');
    });

    test(
        'setChannelManager(m) → setChannelManager(m) does not emit AsyncLoading',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('idem-2').future);
      final notifier = container.read(tmuxProvider('idem-2').notifier);

      final m = _makeFullSuccessManager();
      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Listen for any state change after the first init completes.
      var seenLoading = false;
      container.listen(tmuxProvider('idem-2'), (_, next) {
        if (next is AsyncLoading) seenLoading = true;
      });

      // Second call with the same instance: guard must skip _initializeState.
      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seenLoading, isFalse,
          reason:
              'identical manager guard must not trigger AsyncLoading or re-init');
    });
  });

  // ---------------------------------------------------------------------------
  // _checkAvailability() non-zero exit code → TmuxNotInstalled — Phase 62
  //
  // When `tmux -V` returns a non-zero exit code (e.g. 1 or 127), the
  // _checkAvailability() method returns TmuxNotInstalled (not TmuxAvailable),
  // and _initializeState() sets state to TmuxState(TmuxNotInstalled).
  // This differs from the throw-path (tested in '_initializeState() error
  // recovery') which exercises the catch block.  Here exitCode != 0 triggers
  // the explicit guard on line 232 of tmux_provider.dart.
  // ---------------------------------------------------------------------------

  group('_checkAvailability() non-zero exit code → TmuxNotInstalled', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('tmux -V exit code 1 → TmuxNotInstalled', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('ca-ec-1').future);
      final notifier = container.read(tmuxProvider('ca-ec-1').notifier);

      // Manager returns exitCode 1 for every command (tmux not installed).
      final m = _MockSshChannelManager();
      final versionFail = _makeSession(exitCode: 1);
      when(() => m.executeCommand(any()))
          .thenAnswer((_) => Future.value(versionFail));

      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(tmuxProvider('ca-ec-1'));
      expect(state, isA<AsyncData<TmuxState>>(),
          reason: 'must stay AsyncData even when tmux -V returns exit 1');
      expect(state.value?.isAvailable, isFalse,
          reason:
              'exitCode 1 from tmux -V must map to TmuxNotInstalled via exit-code guard');
      expect(state.value?.sessions, isEmpty);
    });

    test('tmux -V exit code 127 (command not found) → TmuxNotInstalled',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('ca-ec-127').future);
      final notifier = container.read(tmuxProvider('ca-ec-127').notifier);

      // 127 = shell "command not found" — tmux is not in PATH.
      final m = _MockSshChannelManager();
      final versionFail = _makeSession(exitCode: 127);
      when(() => m.executeCommand(any()))
          .thenAnswer((_) => Future.value(versionFail));

      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(tmuxProvider('ca-ec-127'));
      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.isAvailable, isFalse,
          reason:
              'exitCode 127 (tmux not in PATH) must result in TmuxNotInstalled');
      expect(state.value?.sessions, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // _checkAvailability() version string guard — Phase 45
  //
  // When `tmux -V` returns a null exit code (dartssh2 limitation) but the
  // output is empty or does not start with 'tmux', _checkAvailability() must
  // return TmuxNotInstalled.
  //
  // The guard:
  //   if (version.isEmpty || !version.toLowerCase().startsWith('tmux'))
  // catches cases where the SSH exec channel closed without error but produced
  // no useful output — e.g. a non-Linux server that cannot determine exit codes.
  // ---------------------------------------------------------------------------

  group('_checkAvailability() version string guard (null exitCode)', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test('empty stdout with null exitCode → TmuxNotInstalled', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('ca-vg-empty').future);
      final notifier = container.read(tmuxProvider('ca-vg-empty').notifier);

      // exitCode null + empty stdout simulates the dartssh2 limitation where
      // the exit code is unavailable even when tmux is not installed.
      final m = _MockSshChannelManager();
      final emptySession = _makeSession(stdout: const [], exitCode: null);
      when(() => m.executeCommand(any()))
          .thenAnswer((_) => Future.value(emptySession));

      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(tmuxProvider('ca-vg-empty'));
      expect(state, isA<AsyncData<TmuxState>>(),
          reason: 'must stay AsyncData when tmux -V output is empty');
      expect(state.value?.isAvailable, isFalse,
          reason: 'empty tmux -V output with null exitCode → TmuxNotInstalled '
              'via version.isEmpty guard');
      expect(state.value?.sessions, isEmpty);
    });

    test('non-tmux output with null exitCode → TmuxNotInstalled', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('ca-vg-nontmux').future);
      final notifier = container.read(tmuxProvider('ca-vg-nontmux').notifier);

      // exitCode null + error message in stdout (not starting with 'tmux')
      // simulates a shell that echoes an error without a proper exit code.
      final m = _MockSshChannelManager();
      final errorSession = _makeSession(
        stdout: utf8.encode('bash: tmux: command not found\n'),
        exitCode: null,
      );
      when(() => m.executeCommand(any()))
          .thenAnswer((_) => Future.value(errorSession));

      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(tmuxProvider('ca-vg-nontmux'));
      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.isAvailable, isFalse,
          reason: 'non-tmux output with null exitCode → TmuxNotInstalled '
              'via !version.startsWith("tmux") guard');
      expect(state.value?.sessions, isEmpty);
    });

    test('valid "tmux 3.3a" output with null exitCode → TmuxAvailable',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(tmuxProvider('ca-vg-valid').future);
      final notifier = container.read(tmuxProvider('ca-vg-valid').notifier);

      final m = _MockSshChannelManager();
      // Valid tmux version, exitCode null (dartssh2 may return null on success too).
      final versionSession = _makeSession(
        stdout: utf8.encode('tmux 3.3a\n'),
        exitCode: null,
      );
      // list-sessions: return empty (no sessions yet).
      final listSession = _makeSession(
        stdout: utf8.encode(''),
        exitCode: 0,
      );
      when(() => m.executeCommand(any())).thenAnswer((invocation) async {
        final cmd = invocation.positionalArguments[0] as String;
        if (cmd.contains('tmux -V')) return versionSession;
        return listSession;
      });

      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(tmuxProvider('ca-vg-valid'));
      expect(state, isA<AsyncData<TmuxState>>());
      expect(state.value?.isAvailable, isTrue,
          reason: '"tmux 3.3a" with null exitCode must pass version guard '
              '→ TmuxAvailable');
      expect(
        (state.value?.availability as TmuxAvailable?)?.version,
        'tmux 3.3a',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // _runCommand() session lifecycle — session.close() must always be called
  //
  // Each exec channel opened by _runCommand() must be closed in a finally
  // block so that SSH channel resources are freed even on timeout or error.
  // This is verified by stubbing close() on the mock session and checking
  // that it was called after executing tmux commands (killSession / createSession).
  // ---------------------------------------------------------------------------

  group('_runCommand() always closes the SSH exec channel', () {
    late ProviderContainer container;
    late TmuxNotifier notifier;

    setUp(() async {
      container = ProviderContainer();
      addTearDown(container.dispose);
      // Wait for initial build (no channel manager yet → TmuxNotInstalled).
      await container.read(tmuxProvider('rc-close-test').future);
      notifier = container.read(tmuxProvider('rc-close-test').notifier);
    });

    test('session.close() is called after a successful killSession command',
        () async {
      // Build a manager where every executeCommand() returns a fresh session.
      // Pre-create sessions so we can verify close() on each one.
      final versionSession = _makeSession(
        stdout: utf8.encode('tmux 3.3a\n'),
        exitCode: null,
      );
      final listSession = _makeSession(
        stdout: utf8.encode(''),
        exitCode: 0,
      );
      // The kill-session command session — this is the one we care about.
      final killSession = _makeSession(exitCode: 0);

      final m = _MockSshChannelManager();
      when(() => m.executeCommand(any())).thenAnswer((invocation) async {
        final cmd = invocation.positionalArguments[0] as String;
        if (cmd.contains('tmux -V')) return versionSession;
        if (cmd.contains('list-sessions')) return listSession;
        return killSession; // kill-session + any other command
      });

      notifier.setChannelManager(m);
      // Wait for _initializeState to complete.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.killSession('work');

      // close() must have been called on the kill-session exec channel.
      verify(() => killSession.close()).called(greaterThanOrEqualTo(1));
    });

    test('session.close() is called after a successful createSession command',
        () async {
      final versionSession = _makeSession(
        stdout: utf8.encode('tmux 3.3a\n'),
        exitCode: null,
      );
      final listSession = _makeSession(
        stdout: utf8.encode(''),
        exitCode: 0,
      );
      final createSession = _makeSession(exitCode: 0);
      final mouseSession = _makeSession(exitCode: 0);

      final m = _MockSshChannelManager();
      when(() => m.executeCommand(any())).thenAnswer((invocation) async {
        final cmd = invocation.positionalArguments[0] as String;
        if (cmd.contains('tmux -V')) return versionSession;
        if (cmd.contains('list-sessions')) return listSession;
        if (cmd.contains('new-session')) return createSession;
        // set-option for mouse mode comes after new-session.
        return mouseSession;
      });

      notifier.setChannelManager(m);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.createSession('work');

      verify(() => createSession.close()).called(greaterThanOrEqualTo(1));
    });
  });

  // ---------------------------------------------------------------------------
  // _runCommand() session.done timeout is non-fatal
  //
  // When the SSH server is slow to send the channel-close ACK (done future),
  // _runCommand() must still return the collected output rather than propagating
  // the TimeoutException.  This prevents a slow close-ACK from masking a
  // successfully completed command.
  //
  // Verified with fakeAsync: the 2-second close-ACK timer fires while the
  // done future is still pending, but the result is still returned correctly.
  // ---------------------------------------------------------------------------

  group('_runCommand() session.done timeout is non-fatal', () {
    setUpAll(() {
      registerFallbackValue('');
    });

    test(
        'sessions are fetched successfully when session.done times out after 2 s',
        () {
      // Arrange: list-sessions session whose close-ACK (done) never resolves.
      // stdout and stderr complete immediately (realistic: command finished,
      // server just hasn't sent the channel-close packet yet).
      final hangingDoneListSession = _MockSSHSession();
      when(() => hangingDoneListSession.stdout).thenAnswer(
        (_) => Stream.value(
          Uint8List.fromList(utf8.encode('work|||2|||1|||1700000000\n')),
        ),
      );
      when(() => hangingDoneListSession.stderr)
          .thenAnswer((_) => const Stream<Uint8List>.empty());
      // done future never completes — simulates a stuck close-ACK.
      when(() => hangingDoneListSession.done)
          .thenAnswer((_) => Completer<void>().future);
      when(() => hangingDoneListSession.exitCode).thenReturn(0);
      when(() => hangingDoneListSession.close()).thenReturn(null);

      // versionSession completes normally (done resolves immediately).
      final versionSession = _makeSession(
        stdout: utf8.encode('tmux 3.3a\n'),
        exitCode: null,
      );

      final m = _MockSshChannelManager();
      when(() => m.executeCommand(any())).thenAnswer((inv) async {
        final cmd = inv.positionalArguments[0] as String;
        if (cmd.contains('tmux -V')) return versionSession;
        return hangingDoneListSession; // list-sessions
      });

      fakeAsync((async) {
        final container = ProviderContainer();

        // Kick off initial build (channelManager == null → TmuxNotInstalled).
        container.read(tmuxProvider('done-timeout-test'));
        async.flushMicrotasks();

        final notifier =
            container.read(tmuxProvider('done-timeout-test').notifier);

        // setChannelManager triggers _initializeState asynchronously.
        notifier.setChannelManager(m);

        // Drain microtasks: executeCommand + stream collection for both
        // tmux -V (done resolves immediately) and list-sessions (streams
        // complete immediately but done is stuck).
        async.flushMicrotasks();

        // Now _runCommand is waiting on hangingDoneListSession.done.timeout(2s).
        // Advance the fake clock past the 2-second close-ACK deadline.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        // _fetchSessions then calls _detectClaudeRunningPerSession, which issues
        // another exec command hitting the same hanging session — advance another
        // 2 s to let its close-ACK timeout fire as well.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        // With the fix the TimeoutException is caught and _fetchSessions
        // returns the sessions, so state must reflect the parsed session.
        final state = container.read(tmuxProvider('done-timeout-test'));
        expect(
          state.valueOrNull?.sessions,
          hasLength(1),
          reason: 'session must be returned even when done times out',
        );
        expect(
          state.valueOrNull?.sessions.first.name,
          'work',
          reason: 'session name must be parsed from the collected stdout',
        );
        expect(
          state.valueOrNull?.isAvailable,
          isTrue,
          reason: 'tmux must be seen as available after successful check',
        );

        // session.close() must still be called despite the done timeout.
        verify(() => hangingDoneListSession.close())
            .called(greaterThanOrEqualTo(1));

        container.dispose();
      });
    });
  });

}
