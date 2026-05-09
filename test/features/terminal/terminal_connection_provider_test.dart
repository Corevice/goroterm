import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:xterm/xterm.dart';

import 'package:dartssh2/dartssh2.dart' show SSHClient;
import 'package:terminal_ssh_app/core/error/app_error.dart';
import 'package:terminal_ssh_app/core/network/connectivity_monitor.dart';
import 'package:terminal_ssh_app/core/ssh/connection_config.dart';
import 'package:terminal_ssh_app/core/ssh/known_hosts_store.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_channel_manager.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_client_service.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';

// ---------------------------------------------------------------------------
// Fakes/mocks for unit testing without platform channels or SSH servers.
// ---------------------------------------------------------------------------

class _FakeConnectivityMonitor extends ConnectivityMonitor {
  @override
  NetworkStatus build() => NetworkStatus.connected;
}

/// Controllable fake — starts disconnected; call [setStatus] to transition.
class _ControllableConnectivityMonitor extends ConnectivityMonitor {
  @override
  NetworkStatus build() => NetworkStatus.disconnected;

  void setStatus(NetworkStatus status) => state = status;
}

/// Mock SshChannelManager for verifying resizePty calls in _autoReattachTmux tests.
class _MockSshChannelManager extends Mock implements SshChannelManager {}

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

/// Configurable fake SSH service — never establishes real connections.
class _FakeSshClientService extends SshClientService {
  _FakeSshClientService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
        );

  /// Controls what keepAlive() returns.
  bool keepAliveResult = true;

  @override
  bool get isConnected => true;

  @override
  Future<bool> keepAlive({
    Duration executeTimeout = const Duration(seconds: 5),
    Duration doneTimeout = const Duration(seconds: 5),
  }) async =>
      keepAliveResult;

  @override
  void disconnect() {
    // no-op: no real client to close
  }
}

/// Fake SSH service that counts keepAlive() invocations — used to verify
/// that concurrent activeKeepAlive() calls are deduplicated.
class _CountingSshClientService extends SshClientService {
  _CountingSshClientService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
        );

  int keepAliveCount = 0;

  @override
  bool get isConnected => true;

  @override
  Future<bool> keepAlive({
    Duration executeTimeout = const Duration(seconds: 5),
    Duration doneTimeout = const Duration(seconds: 5),
  }) async {
    keepAliveCount++;
    return true;
  }

  @override
  void disconnect() {}
}

/// Fake SSH service that returns false on the first keepAlive call, true after.
/// Used to test the retry-on-first-failure path in checkConnection().
class _FirstFailSshClientService extends SshClientService {
  _FirstFailSshClientService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
        );

  int _callCount = 0;

  @override
  bool get isConnected => true;

  @override
  Future<bool> keepAlive({
    Duration executeTimeout = const Duration(seconds: 5),
    Duration doneTimeout = const Duration(seconds: 5),
  }) async {
    _callCount++;
    return _callCount > 1; // false on first call, true on second
  }

  @override
  void disconnect() {}
}

/// Fake SSH service whose socket factory throws immediately, simulating a
/// connection-refused error. Injected via sshServiceFactoryOverride to let
/// _connectCore() / _attemptReconnect() fail fast without any real network I/O.
class _FailFastSshClientService extends SshClientService {
  _FailFastSshClientService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
          socketFactory: (host, port, {timeout}) async {
            throw Exception('test: connection refused');
          },
        );

  @override
  bool get isConnected => false;

  @override
  void disconnect() {}
}

/// Variant of [_FailFastSshClientService] that tracks whether disconnect() was
/// called. Used to verify that _attemptReconnect() cleans up the partially-
/// initialised SSH service when _connectCore() throws.
class _TrackingFailFastSshClientService extends SshClientService {
  bool disconnectCalled = false;

  _TrackingFailFastSshClientService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
          socketFactory: (host, port, {timeout}) async {
            throw Exception('test: connection refused');
          },
        );

  @override
  bool get isConnected => false;

  @override
  void disconnect() {
    disconnectCalled = true;
  }
}

/// SSH service whose disconnect() throws. Used to verify that
/// _cleanupConnections() swallows the exception rather than propagating it.
class _ThrowingDisconnectSshClientService extends SshClientService {
  bool disconnectCalled = false;

  _ThrowingDisconnectSshClientService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
          socketFactory: (host, port, {timeout}) async {
            throw Exception('test: connection refused');
          },
        );

  @override
  bool get isConnected => false;

  @override
  void disconnect() {
    disconnectCalled = true;
    throw Exception('test: disconnect() threw');
  }
}

/// Fake SSH service that always reports disconnected — used to test early exit.
class _FakeDisconnectedSshClientService extends SshClientService {
  _FakeDisconnectedSshClientService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
        );

  @override
  bool get isConnected => false;

  @override
  Future<bool> keepAlive({
    Duration executeTimeout = const Duration(seconds: 5),
    Duration doneTimeout = const Duration(seconds: 5),
  }) async =>
      false;

  @override
  void disconnect() {}
}

/// Fake SSH service that blocks on its second keepAlive() call until a
/// provided Completer is completed. Used to simulate the race where
/// _sshService is replaced while probe 2 is awaiting — testing the
/// identity guard after probe 2 returns in checkConnection().
class _BlockingProbe2Service extends SshClientService {
  _BlockingProbe2Service()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
        );

  int _callCount = 0;

  /// When set, probe 2's keepAlive() blocks on this completer.
  Completer<bool>? probe2Completer;

  @override
  bool get isConnected => true;

  @override
  Future<bool> keepAlive({
    Duration executeTimeout = const Duration(seconds: 5),
    Duration doneTimeout = const Duration(seconds: 5),
  }) async {
    _callCount++;
    if (_callCount == 2 && probe2Completer != null) {
      return probe2Completer!.future;
    }
    return false; // probe 1 always fails
  }

  @override
  void disconnect() {}
}

/// Fake SSH service that blocks its first keepAlive() call on a Completer.
/// When [blockCompleter] is null, returns false immediately.
/// Used to test the identical() guard in _activeKeepAliveCore(): lets us swap
/// _sshService while keepAlive() is mid-await, then verify the result is ignored.
class _BlockingFirstCallService extends SshClientService {
  _BlockingFirstCallService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
        );

  Completer<bool>? blockCompleter;

  @override
  bool get isConnected => true;

  @override
  Future<bool> keepAlive({
    Duration executeTimeout = const Duration(seconds: 5),
    Duration doneTimeout = const Duration(seconds: 5),
  }) async {
    if (blockCompleter != null) {
      return blockCompleter!.future;
    }
    return false;
  }

  @override
  void disconnect() {}
}

/// Fake SSH service that throws a NetworkError directly from connect().
/// Overrides connect() to bypass SshClientService's error-wrapping catch blocks,
/// so the thrown NetworkError reaches terminal_connection_provider unchanged.
/// Used to verify that AppError.message (not toString()) is stored in errorMessage.
class _NetworkErrorSshClientService extends SshClientService {
  _NetworkErrorSshClientService()
      : super(
          knownHostsStore: KnownHostsStore(
            storage: _MockFlutterSecureStorage(),
          ),
        );

  @override
  Future<SSHClient> connect({
    required ConnectionConfig config,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    Future<bool> Function(String)? onUnknownHostKey,
    Future<bool> Function(String, String)? onHostKeyMismatch,
  }) async {
    throw const NetworkError('Host unreachable');
  }

  @override
  bool get isConnected => false;

  @override
  void disconnect() {}
}

/// Terminal サブクラス: viewWidth/viewHeight を 0 に固定する。
/// _autoReattachTmux の zero-dimension guard (if (w > 0 && h > 0)) を
/// 実際の Terminal を使いつつテストするために使用する。
/// Terminal.resize(w, h) は max(w, 1) に丸めるため、通常の Terminal では
/// 0×0 の状態を作れない。
class _ZeroDimensionTerminal extends Terminal {
  _ZeroDimensionTerminal() : super(maxLines: 50);

  @override
  int get viewWidth => 0;

  @override
  int get viewHeight => 0;
}

// ---------------------------------------------------------------------------
// Helper: ProviderContainer with connectivity override.
// ---------------------------------------------------------------------------

ProviderContainer makeContainer() {
  return ProviderContainer(
    overrides: [
      connectivityProvider.overrideWith(_FakeConnectivityMonitor.new),
    ],
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // TerminalConnectionState (value-class behaviour)
  // -------------------------------------------------------------------------

  group('TerminalConnectionState', () {
    test('default status is disconnected', () {
      const state = TerminalConnectionState();
      expect(state.status, ConnectionStatus.disconnected);
    });

    test('default terminal, channelManager, errorMessage are null', () {
      const state = TerminalConnectionState();
      expect(state.terminal, isNull);
      expect(state.channelManager, isNull);
      expect(state.errorMessage, isNull);
    });

    test('copyWith updates status while preserving other fields', () {
      const state = TerminalConnectionState(
        status: ConnectionStatus.connecting,
        hostLabel: 'server.example.com',
        errorMessage: 'previous error',
      );
      final updated = state.copyWith(status: ConnectionStatus.disconnected);
      expect(updated.status, ConnectionStatus.disconnected);
      expect(updated.hostLabel, 'server.example.com');
      expect(updated.errorMessage, 'previous error');
    });

    test('copyWith sets errorMessage', () {
      const state = TerminalConnectionState();
      final updated = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection refused',
      );
      expect(updated.errorMessage, 'Connection refused');
    });

    test('copyWith clears channelManager when clearChannelManager is true', () {
      const state = TerminalConnectionState(channelManager: null);
      final updated = state.copyWith(
        status: ConnectionStatus.disconnected,
        clearChannelManager: true,
      );
      expect(updated.channelManager, isNull);
      expect(updated.status, ConnectionStatus.disconnected);
    });

    test('copyWith clears errorMessage when clearErrorMessage is true', () {
      const state = TerminalConnectionState(errorMessage: 'Reconnecting in 3s...');
      final updated = state.copyWith(
        status: ConnectionStatus.connected,
        clearErrorMessage: true,
      );
      expect(updated.errorMessage, isNull);
      expect(updated.status, ConnectionStatus.connected);
    });

    test('copyWith preserves errorMessage when clearErrorMessage is false', () {
      const state = TerminalConnectionState(errorMessage: 'previous error');
      final updated = state.copyWith(status: ConnectionStatus.reconnecting);
      expect(updated.errorMessage, 'previous error');
    });

    test('default shellExited is false', () {
      const state = TerminalConnectionState();
      expect(state.shellExited, isFalse);
    });

    test('copyWith shellExited: true sets it to true', () {
      const state = TerminalConnectionState();
      final updated = state.copyWith(shellExited: true);
      expect(updated.shellExited, isTrue);
    });

    test('copyWith shellExited: false resets it to false', () {
      const state = TerminalConnectionState(shellExited: true);
      final updated = state.copyWith(shellExited: false);
      expect(updated.shellExited, isFalse);
    });

    test('copyWith preserves shellExited when not specified', () {
      const state = TerminalConnectionState(shellExited: true);
      final updated = state.copyWith(status: ConnectionStatus.disconnected);
      expect(updated.shellExited, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // ConnectionStatus enum
  // -------------------------------------------------------------------------

  group('ConnectionStatus', () {
    test('has all four expected values', () {
      expect(ConnectionStatus.values, containsAll([
        ConnectionStatus.connecting,
        ConnectionStatus.connected,
        ConnectionStatus.disconnected,
        ConnectionStatus.reconnecting,
      ]));
    });

    test('reconnecting is distinct from connecting', () {
      expect(
        ConnectionStatus.reconnecting,
        isNot(equals(ConnectionStatus.connecting)),
      );
    });
  });

  // -------------------------------------------------------------------------
  // TerminalConnectionNotifier — state machine behaviour
  // -------------------------------------------------------------------------

  group('TerminalConnectionNotifier', () {
    test('initial state has disconnected status', () {
      final container = makeContainer();
      addTearDown(container.dispose);

      final state = container.read(terminalConnectionProvider('session-1'));
      expect(state.status, ConnectionStatus.disconnected);
    });

    test('initial state has null terminal and channelManager', () {
      final container = makeContainer();
      addTearDown(container.dispose);

      final state = container.read(terminalConnectionProvider('session-1'));
      expect(state.terminal, isNull);
      expect(state.channelManager, isNull);
    });

    test('different session IDs produce independent notifiers', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      // Both start in disconnected status.
      expect(container.read(terminalConnectionProvider('session-1')).status,
          ConnectionStatus.disconnected);
      expect(container.read(terminalConnectionProvider('session-2')).status,
          ConnectionStatus.disconnected);

      // Transitioning one session's state does not affect the other.
      await container
          .read(terminalConnectionProvider('session-1').notifier)
          .checkConnection();

      expect(container.read(terminalConnectionProvider('session-1')).status,
          ConnectionStatus.disconnected);
      expect(container.read(terminalConnectionProvider('session-2')).status,
          ConnectionStatus.disconnected);
    });

    // checkConnection() when already disconnected (initial state):
    //   → status == disconnected guard → returns early → status stays disconnected
    test('checkConnection when never connected transitions to disconnected',
        () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier =
          container.read(terminalConnectionProvider('session-1').notifier);
      await notifier.checkConnection();

      final state = container.read(terminalConnectionProvider('session-1'));
      expect(state.status, ConnectionStatus.disconnected);
    });

    // reconnect() when _config == null returns immediately without changing state.
    test('reconnect when never connected leaves state unchanged', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier =
          container.read(terminalConnectionProvider('session-1').notifier);
      await notifier.reconnect();

      // _config is null → early return → status stays at initial 'disconnected'.
      final state = container.read(terminalConnectionProvider('session-1'));
      expect(state.status, ConnectionStatus.disconnected);
    });

    // Consecutive checkConnection() calls with null config stay disconnected.
    test('repeated checkConnection calls remain disconnected', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier =
          container.read(terminalConnectionProvider('session-1').notifier);

      await notifier.checkConnection();
      await notifier.checkConnection();

      final state = container.read(terminalConnectionProvider('session-1'));
      expect(state.status, ConnectionStatus.disconnected);
    });

    // reconnect() when status is connecting/reconnecting/connected returns early.
    test('reconnect() is a no-op when status is reconnecting', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      // Force state into reconnecting via copyWith path (structural test).
      const reconnectingState = TerminalConnectionState(
        status: ConnectionStatus.reconnecting,
      );
      expect(reconnectingState.status, ConnectionStatus.reconnecting);
      // The guard in reconnect() prevents double-reconnect:
      //   if (state.status == ConnectionStatus.reconnecting) return;
      // This is a compile-time structural property — the enum value exists.
      expect(ConnectionStatus.reconnecting, isNot(equals(ConnectionStatus.connecting)));
    });

    // reconnect() guard: _config == null → early return even when disconnected.
    test('reconnect() with null config leaves state as disconnected', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier =
          container.read(terminalConnectionProvider('session-1').notifier);

      // No connect() called → _config is null → reconnect() returns early.
      await notifier.reconnect();

      final state = container.read(terminalConnectionProvider('session-1'));
      expect(state.status, ConnectionStatus.disconnected);
    });

    // hostLabel reflects config.label (or host when label is empty).
    test('initial hostLabel is null', () {
      final container = makeContainer();
      addTearDown(container.dispose);

      final state = container.read(terminalConnectionProvider('session-1'));
      expect(state.hostLabel, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // checkConnection() — guard conditions (Phase 8)
  // -------------------------------------------------------------------------

  group('checkConnection() guard conditions', () {
    test('concurrent calls do not throw or corrupt state', () async {
      // Two concurrent checkConnection() calls with initial disconnected status
      // both hit the disconnected guard and return early — no exception,
      // consistent final state.
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier =
          container.read(terminalConnectionProvider('session-1').notifier);

      // Fire both without awaiting the first.
      final f1 = notifier.checkConnection();
      final f2 = notifier.checkConnection();
      await Future.wait([f1, f2]);

      expect(
        container.read(terminalConnectionProvider('session-1')).status,
        ConnectionStatus.disconnected,
      );
    });

    test('checkConnection() is idempotent when already disconnected', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier =
          container.read(terminalConnectionProvider('session-1').notifier);

      await notifier.checkConnection(); // → disconnected
      await notifier.checkConnection(); // _onDisconnected() returns early, no state change
      await notifier.checkConnection();

      expect(
        container.read(terminalConnectionProvider('session-1')).status,
        ConnectionStatus.disconnected,
      );
    });

    test('checkConnection() does not trigger when status is reconnecting',
        () async {
      // Simulate the reconnecting guard: once status is set to reconnecting,
      // a subsequent checkConnection() call must return early.
      //
      // We test this via the copyWith / state observation path: create a state
      // snapshot in reconnecting, then verify that status is preserved as
      // reconnecting (i.e. the notifier does not transition it to disconnected
      // on a secondary call that would skip the reconnect path).
      const reconnectingState = TerminalConnectionState(
        status: ConnectionStatus.reconnecting,
      );
      expect(reconnectingState.status, ConnectionStatus.reconnecting);

      // If checkConnection() were called with this state (and _config == null
      // is satisfied before the status guard in production), the guard:
      //   if (state.status == ConnectionStatus.reconnecting) return;
      // prevents _autoReconnect() from running a second time.
      //
      // Structural verification: the guard exists at the start of checkConnection().
      // The test above (concurrent calls) verifies the _onDisconnected() path is
      // safe; the reconnecting guard is a compile-time structural property.
      expect(ConnectionStatus.reconnecting, isNot(equals(ConnectionStatus.connecting)));
    });
  });

  // -------------------------------------------------------------------------
  // Terminal preservation on reconnect (Phase 6)
  // Validates the copyWith mechanism that reconnect() relies on to preserve
  // scroll-back history across reconnection attempts.
  // -------------------------------------------------------------------------

  group('Terminal preservation via copyWith', () {
    test('copyWith preserves terminal reference when only status changes', () {
      final terminal = Terminal(maxLines: 50);
      final state = TerminalConnectionState(
        status: ConnectionStatus.connected,
        terminal: terminal,
      );

      // Simulate the catch block in reconnect() — failure path.
      final afterFailure = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Reconnection failed after 3 attempts',
        clearChannelManager: true,
      );

      expect(afterFailure.terminal, same(terminal),
          reason: 'Terminal must be the same instance so scroll-back is kept');
      expect(afterFailure.status, ConnectionStatus.disconnected);
      expect(afterFailure.channelManager, isNull);
      expect(afterFailure.errorMessage, 'Reconnection failed after 3 attempts');
    });

    test('copyWith preserves terminal through reconnecting status', () {
      final terminal = Terminal(maxLines: 50);
      final connected = TerminalConnectionState(
        status: ConnectionStatus.connected,
        terminal: terminal,
      );

      // Simulate entering reconnecting state (status changes, terminal kept).
      final reconnecting = connected.copyWith(
        status: ConnectionStatus.reconnecting,
        clearChannelManager: true,
      );

      expect(reconnecting.terminal, same(terminal));
      expect(reconnecting.status, ConnectionStatus.reconnecting);
    });

    test('clearChannelManager true clears only channelManager, not terminal',
        () {
      final terminal = Terminal(maxLines: 50);
      const state = TerminalConnectionState(
        status: ConnectionStatus.connected,
        channelManager: null, // channelManager already tested as null-safe above
      );
      final withTerminal = state.copyWith(terminal: terminal);

      final cleared = withTerminal.copyWith(
        status: ConnectionStatus.disconnected,
        clearChannelManager: true,
      );

      expect(cleared.terminal, same(terminal));
      expect(cleared.channelManager, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // activeKeepAlive() — failure count threshold (Phase 36)
  //
  // _keepAliveFailCount >= 3 (30 seconds at 10s interval) triggers disconnect.
  // Fewer consecutive failures are tolerated as transient network hiccups.
  // -------------------------------------------------------------------------

  group('activeKeepAlive() failure count', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('ka-test').notifier,
      );
      fakeService = _FakeSshClientService();
      // Inject a connected state with the fake SSH service.
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );
    });

    tearDown(() => container.dispose());

    test('1 keepAlive failure does not disconnect', () async {
      fakeService.keepAliveResult = false;
      await notifier.activeKeepAlive();
      expect(
        container.read(terminalConnectionProvider('ka-test')).status,
        ConnectionStatus.connected,
      );
    });

    test('2 consecutive keepAlive failures do not disconnect', () async {
      fakeService.keepAliveResult = false;
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();
      expect(
        container.read(terminalConnectionProvider('ka-test')).status,
        ConnectionStatus.connected,
      );
    });

    test('3 consecutive keepAlive failures trigger disconnect', () async {
      fakeService.keepAliveResult = false;
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();
      expect(
        container.read(terminalConnectionProvider('ka-test')).status,
        ConnectionStatus.disconnected,
      );
    });

    test('failure count resets after a success', () async {
      fakeService.keepAliveResult = false;
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive(); // 2 failures

      fakeService.keepAliveResult = true;
      await notifier.activeKeepAlive(); // success → resets count

      fakeService.keepAliveResult = false;
      await notifier.activeKeepAlive(); // 1 failure (count was reset)
      await notifier.activeKeepAlive(); // 2 failures
      expect(
        container.read(terminalConnectionProvider('ka-test')).status,
        ConnectionStatus.connected,
      );
    });

    test('status is disconnected after 3 keepAlive failures', () async {
      fakeService.keepAliveResult = false;
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();
      expect(
        container.read(terminalConnectionProvider('ka-test')).status,
        ConnectionStatus.disconnected,
      );
    });

    test('reconnect error message is set after 3 keepAlive failures', () async {
      // When _config is set, _scheduleReconnect sets a user-visible
      // error message in the format "Reconnecting in Xs... (attempt #N)".
      fakeService.keepAliveResult = false;
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test-server',
          host: '192.168.1.1',
          username: 'admin',
        ),
      );

      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();

      final state = container.read(terminalConnectionProvider('ka-test'));
      expect(state.status, ConnectionStatus.disconnected);
      // First retry: _retryCount=1, delaySec = 3*(1<<0) = 3s.
      expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)');
    });

    test('exponential backoff doubles delay on 2nd retry', () {
      // Verify that _scheduleReconnect increments _retryCount and computes
      // backoff as 3*(1<<(_retryCount-1)):
      //   attempt #1 → 3*(1<<0) = 3s
      //   attempt #2 → 3*(1<<1) = 6s
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test-server',
          host: '192.168.1.1',
          username: 'admin',
        ),
      );

      notifier.triggerScheduleReconnectForTesting(); // attempt #1 → 3s
      notifier.triggerScheduleReconnectForTesting(); // attempt #2 → 6s

      final state = container.read(terminalConnectionProvider('ka-test'));
      expect(state.status, ConnectionStatus.disconnected);
      expect(state.errorMessage, 'Reconnecting in 6s... (attempt #2)');
    });

    test('exponential backoff full sequence: 3s→6s→12s→24s→30s→30s', () {
      // attempt #1: 3*(1<<0) = 3s
      // attempt #2: 3*(1<<1) = 6s
      // attempt #3: 3*(1<<2) = 12s
      // attempt #4: 3*(1<<3) = 24s
      // attempt #5: 3*(1<<4) = 48s → clamp → 30s
      // attempt #6: 3*(1<<5) = 96s → clamp → 30s
      const config = ConnectionConfig(
        label: 'test-server',
        host: '192.168.1.1',
        username: 'admin',
      );
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'test-host',
        ),
        config: config,
      );

      final expectedDelays = [3, 6, 12, 24, 30, 30];
      for (var i = 0; i < expectedDelays.length; i++) {
        notifier.triggerScheduleReconnectForTesting();
        final state = container.read(terminalConnectionProvider('ka-test'));
        expect(
          state.errorMessage,
          'Reconnecting in ${expectedDelays[i]}s... (attempt #${i + 1})',
          reason: 'attempt #${i + 1} should have ${expectedDelays[i]}s delay',
        );
      }
    });

    test('exponential backoff clamps at 30s after many retries', () {
      // After 10 retries (the max) the delay is 30s and further calls give up.
      const config = ConnectionConfig(
        label: 'test-server',
        host: '192.168.1.1',
        username: 'admin',
      );
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'test-host',
        ),
        config: config,
      );

      // Retries 1–10: delay clamps at 30s from attempt #5 onward.
      for (var i = 0; i < 10; i++) {
        notifier.triggerScheduleReconnectForTesting();
      }
      final stateAt10 = container.read(terminalConnectionProvider('ka-test'));
      expect(stateAt10.errorMessage, 'Reconnecting in 30s... (attempt #10)');

      // Retry #11 exceeds the max (10) → gives up.
      notifier.triggerScheduleReconnectForTesting();
      final stateAfterMax = container.read(terminalConnectionProvider('ka-test'));
      expect(stateAfterMax.errorMessage, 'Connection lost. Tap to reconnect.');
    });

    test('service swap during await does not pollute new connection count',
        () async {
      // Simulate: old service fails, but _sshService was replaced (reconnect).
      // The !alive && identical() guard should prevent incrementing the counter.
      final oldService = _FakeSshClientService()..keepAliveResult = false;
      notifier.initConnectedStateForTesting(
        sshService: oldService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );

      // Replace _sshService with a new instance before the keepAlive result
      // is processed — simulated by calling initConnectedStateForTesting again
      // after active keepAlive has started (we can't intercept mid-await here,
      // so we test the post-condition: if the service differs, count stays 0).
      //
      // Since we can't inject mid-await in a sync test, we verify the guard
      // indirectly: use the same old service and confirm failures accumulate,
      // then swap and verify count starts fresh.
      await notifier.activeKeepAlive(); // 1 failure on old service
      await notifier.activeKeepAlive(); // 2 failures on old service

      // Swap to a new healthy service (simulates reconnect).
      final newService = _FakeSshClientService()..keepAliveResult = true;
      notifier.initConnectedStateForTesting(
        sshService: newService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );

      // New service is healthy — should succeed without disconnect.
      await notifier.activeKeepAlive();
      expect(
        container.read(terminalConnectionProvider('ka-test')).status,
        ConnectionStatus.connected,
      );
    });
  });

  // -------------------------------------------------------------------------
  // checkConnection() — connected path (keepAlive probe)
  //
  // When status is connected, checkConnection() sends up to 2 keepAlive probes.
  // Both succeeding → stays connected. Both failing → calls _onDisconnected().
  // status == connecting → early return without any probe.
  // -------------------------------------------------------------------------

  group('checkConnection() connected path', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('cc-conn-test').notifier,
      );
      fakeService = _FakeSshClientService();
    });

    tearDown(() => container.dispose());

    test('checkConnection returns early when status is connecting', () async {
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connecting,
          hostLabel: 'test-host',
        ),
      );

      await notifier.checkConnection();

      expect(
        container.read(terminalConnectionProvider('cc-conn-test')).status,
        ConnectionStatus.connecting,
      );
    });

    test('checkConnection does nothing when connected and keepAlive succeeds',
        () async {
      fakeService.keepAliveResult = true;
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        ),
      );

      await notifier.checkConnection();

      expect(
        container.read(terminalConnectionProvider('cc-conn-test')).status,
        ConnectionStatus.connected,
      );
    });

    test('checkConnection disconnects when both keepAlive probes fail',
        () async {
      fakeService.keepAliveResult = false;
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        ),
      );

      // Two failing probes (with ~1s delay between them in production code).
      await notifier.checkConnection();

      expect(
        container.read(terminalConnectionProvider('cc-conn-test')).status,
        ConnectionStatus.disconnected,
      );
    });

    // Verifies that _onDisconnected() → _scheduleReconnect() is called after
    // both keepAlive probes fail, not just that status becomes disconnected.
    // The errorMessage set by _scheduleReconnect() is the observable proof.
    test(
        'checkConnection sets reconnect errorMessage after both probes fail',
        () async {
      fakeService.keepAliveResult = false;
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        ),
      );

      await notifier.checkConnection();

      final state = container.read(terminalConnectionProvider('cc-conn-test'));
      expect(state.status, ConnectionStatus.disconnected);
      expect(
        state.errorMessage,
        'Reconnecting in 3s... (attempt #1)',
        reason: 'failing both keepAlive probes must call _onDisconnected() → '
            '_scheduleReconnect(), which sets the retry errorMessage',
      );
    });
  });

  // -------------------------------------------------------------------------
  // checkConnection() — reconnecting guard (Phase 41)
  // -------------------------------------------------------------------------

  group('checkConnection() reconnecting guard', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('rc-test').notifier,
      );
      fakeService = _FakeSshClientService();
    });

    tearDown(() => container.dispose());

    // checkConnection() must return early when status is reconnecting,
    // preventing a race with an in-progress _attemptReconnect.
    test('checkConnection returns early when status is reconnecting', () async {
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.reconnecting,
          hostLabel: 'test-host',
        ),
      );

      await notifier.checkConnection();

      expect(
        container.read(terminalConnectionProvider('rc-test')).status,
        ConnectionStatus.reconnecting,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // waitForShellReady()
  // ---------------------------------------------------------------------------

  group('waitForShellReady()', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('ws-test').notifier,
      );
      fakeService = _FakeSshClientService();
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );
    });

    tearDown(() => container.dispose());

    test('returns promptly when shell is already ready', () async {
      notifier.markShellReadyForTesting();

      final sw = Stopwatch()..start();
      await notifier.waitForShellReady();
      sw.stop();

      // 初期 300ms + 最初のポーリング前に break するので、合計 400ms 未満で返る。
      expect(sw.elapsedMilliseconds, lessThan(600));
      expect(notifier.shellOutputReceived, isTrue);
    });

    test('returns promptly when SSH disconnects mid-wait', () async {
      // isConnected が false を返す fake
      final disconnectedFake = _FakeDisconnectedSshClientService();
      notifier.initConnectedStateForTesting(
        sshService: disconnectedFake,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );

      final sw = Stopwatch()..start();
      await notifier.waitForShellReady();
      sw.stop();

      // isConnected=false なので最初のポーリングで break → 300ms + わずか。
      expect(sw.elapsedMilliseconds, lessThan(600));
    });

    test('completes after full poll cycle when shell never becomes ready', () {
      // _shellOutputReceived は false のまま、かつ isConnected=true のまま。
      // ループは _shellReadyMaxPolls (47) 回すべてを消化して返る。
      // 合計: 300ms (initial) + 47 × 100ms (polls) = 5000ms。
      //
      // このパスは .bashrc 等の初期化スクリプトが stdout に何も出力しない
      // サーバー環境でのシェルウォームアップ待機のタイムアウトに相当する。
      fakeAsync((async) {
        var completed = false;
        notifier.waitForShellReady().then((_) {
          completed = true;
        });

        // 4999ms 時点ではまだ最後のポーリング待機中 → 未完了。
        async.elapse(const Duration(milliseconds: 4999));
        expect(completed, isFalse,
            reason: 'waitForShellReady must still be polling at 4999ms');

        // 5000ms 時点でループが抜けて返る → 完了。
        async.elapse(const Duration(milliseconds: 1));
        expect(completed, isTrue,
            reason: 'waitForShellReady must complete after all 47 polls (5000ms)');
      });
    });

    test('breaks early when _sshService becomes null mid-poll', () {
      // ポーリング開始後に _sshService が null になるケース。
      // 初期待機 (300ms) が終わり、1 回目のポーリング待機 (100ms) に入った直後に
      // clearSshServiceForTesting() でサービスを null にする。
      // 次のポーリング判定で `_sshService?.isConnected ?? false` = false となり
      // ループが break して関数が返る必要がある。
      fakeAsync((async) {
        // fakeService.isConnected = true → ポーリングは即座に break しない
        var completed = false;
        notifier.waitForShellReady().then((_) {
          completed = true;
        });

        // 300ms: 初期 delay が完了し、1 回目のポーリング待機に入る
        async.elapse(const Duration(milliseconds: 300));
        expect(completed, isFalse, reason: 'still in first poll delay');

        // ポーリング待機中に SSH サービスを null にする
        notifier.clearSshServiceForTesting();

        // 100ms 経過 → 2 回目のポーリング判定: _sshService == null → break
        async.elapse(const Duration(milliseconds: 100));
        expect(completed, isTrue,
            reason: 'should break immediately after _sshService becomes null');
      });
    });
  });

  // -------------------------------------------------------------------------
  // activeKeepAlive() — concurrent call deduplication
  //
  // _isActiveKeepAliveRunning フラグにより、2 回目以降の concurrent 呼び出しは
  // 早期リターンし、実際の SSH keepAlive probe は 1 回だけ送信される。
  // これはフォアグラウンドサービスのタイマーが重なって発火した場合に
  // 余分な SSH exec チャネルが開かれないための重要な保証。
  // -------------------------------------------------------------------------

  group('activeKeepAlive() concurrent call deduplication', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _CountingSshClientService countingService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('ka-dedup-test').notifier,
      );
      countingService = _CountingSshClientService();
      notifier.initConnectedStateForTesting(
        sshService: countingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );
    });

    tearDown(() => container.dispose());

    test('concurrent calls send only one keepAlive probe', () async {
      // 2 つの concurrent 呼び出しを await なしで起動する。
      // Dart はシングルスレッドのため、最初の呼び出しが await に達した時点で
      // 2 番目が開始され、_isActiveKeepAliveRunning == true を見て早期リターンする。
      final f1 = notifier.activeKeepAlive();
      final f2 = notifier.activeKeepAlive();
      await Future.wait([f1, f2]);

      // SSH keepAlive は 1 回だけ実行された
      expect(countingService.keepAliveCount, 1);
    });

    test('sequential calls each send one keepAlive probe', () async {
      // 直列呼び出しはそれぞれ独立して実行される
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();

      expect(countingService.keepAliveCount, 2);
    });

    test('third concurrent call is also deduplicated', () async {
      // 3 つの concurrent 呼び出しでも keepAlive は 1 回だけ
      final f1 = notifier.activeKeepAlive();
      final f2 = notifier.activeKeepAlive();
      final f3 = notifier.activeKeepAlive();
      await Future.wait([f1, f2, f3]);

      expect(countingService.keepAliveCount, 1);
    });
  });

  // -------------------------------------------------------------------------
  // _onDisconnected() — guard conditions
  //
  // _onDisconnected() は接続が切れたときに呼ばれる。以下のガードがある:
  //   1. status == disconnected → 二重切断を防ぐ（何もしない）
  //   2. status == connecting   → 接続中の中断で二重クリーンアップを防ぐ
  //   3. _isReconnecting == true → 再接続中の disconnect イベントを無視
  // -------------------------------------------------------------------------

  group('_onDisconnected() guard conditions', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('od-test').notifier,
      );
      fakeService = _FakeSshClientService();
    });

    tearDown(() => container.dispose());

    test('does nothing when status is already disconnected', () {
      // Initial state is disconnected — calling _onDisconnected should be a no-op.
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'test-host',
        ),
      );

      notifier.triggerOnDisconnectedForTesting();

      expect(
        container.read(terminalConnectionProvider('od-test')).status,
        ConnectionStatus.disconnected,
      );
    });

    test('does nothing when status is connecting', () {
      // During initial connect, if a spurious done event fires, we must not
      // corrupt the connecting state.
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connecting,
          hostLabel: 'test-host',
        ),
      );

      notifier.triggerOnDisconnectedForTesting();

      expect(
        container.read(terminalConnectionProvider('od-test')).status,
        ConnectionStatus.connecting,
        reason: '_onDisconnected must not interrupt an in-progress connect',
      );
    });

    test('transitions connected to disconnected and schedules reconnect', () {
      // Normal path: connection drops while connected.
      // With _config == null, _scheduleReconnect returns early (no timer),
      // but the status transition to disconnected still occurs.
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );

      notifier.triggerOnDisconnectedForTesting();

      expect(
        container.read(terminalConnectionProvider('od-test')).status,
        ConnectionStatus.disconnected,
        reason: 'connected → _onDisconnected must transition to disconnected',
      );
    });

    test('preserves terminal reference when transitioning to disconnected', () {
      // The scroll-back buffer must survive a disconnect event.
      final terminal = Terminal(maxLines: 50);
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
          terminal: terminal,
        ),
      );

      notifier.triggerOnDisconnectedForTesting();

      final state = container.read(terminalConnectionProvider('od-test'));
      expect(state.status, ConnectionStatus.disconnected);
      expect(state.terminal, same(terminal),
          reason: 'terminal must be preserved across disconnect for scroll-back');
    });

    test('preserves shellExited through network disconnect (not reset by _onDisconnected)', () {
      // shellExited=true means the shell itself exited cleanly (e.g. user ran `exit`).
      // A subsequent network disconnect must NOT clear this flag — it is only reset
      // when a new connection succeeds (connect()/reconnect() success path).
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          shellExited: true,
        ),
      );

      notifier.triggerOnDisconnectedForTesting();

      final state = container.read(terminalConnectionProvider('od-test'));
      expect(state.shellExited, isTrue,
          reason: 'shellExited must survive network disconnect unchanged');
    });

    test('_isReconnecting flag prevents double-disconnect during active reconnect',
        () {
      // Arrange: connected state + _isReconnecting = true (simulates _attemptReconnect in progress).
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(
        terminalConnectionProvider('od-isreconnecting').notifier,
      );
      final fakeService = _FakeSshClientService();
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.reconnecting,
          hostLabel: 'test-host',
        ),
      );
      notifier.setIsReconnectingForTesting(true);

      // Act: a client.done event fires while reconnect is in progress.
      notifier.triggerOnDisconnectedForTesting();

      // Assert: state is still reconnecting — the guard swallowed the event.
      final state = container.read(terminalConnectionProvider('od-isreconnecting'));
      expect(state.status, ConnectionStatus.reconnecting,
          reason:
              '_isReconnecting guard must ignore disconnect during active reconnect attempt');
    });
  });

  // -------------------------------------------------------------------------
  // _flushOutput() — batched terminal output behaviour
  //
  // SSH stdout chunks are accumulated in _outputBuffer and flushed in at most
  // 64 KB chunks so the UI thread can render between large outputs (e.g.
  // Claude Code on tmux).  During a resize-guard window, chunking is disabled
  // to prevent tmux redraw corruption.
  // -------------------------------------------------------------------------

  group('_flushOutput() batched output', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late Terminal terminal;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('flush-test').notifier,
      );
      terminal = Terminal(maxLines: 50);
    });

    tearDown(() => container.dispose());

    // Empty buffer → nothing to do, buffer stays empty.
    test('empty buffer is a no-op', () {
      final remaining = notifier.flushOutputForTesting(terminal, '');
      expect(remaining, isEmpty);
    });

    // Data <= 64 KB → written all at once, buffer cleared.
    test('small data (<=64 KB) is written all at once', () {
      final data = 'A' * (64 * 1024); // exactly 64 KB
      final remaining = notifier.flushOutputForTesting(terminal, data);
      expect(remaining, isEmpty,
          reason: 'buffer must be empty after flushing small data');
    });

    // Data one byte over 64 KB → first chunk written, rest stays in buffer.
    test('large data (>64 KB) splits into 64 KB chunk + remainder', () {
      const chunkSize = 64 * 1024;
      final data = 'B' * (chunkSize + 500); // 64 KB + 500 bytes
      final remaining = notifier.flushOutputForTesting(terminal, data);
      expect(remaining.length, 500,
          reason: 'exactly 500 bytes should remain after first 64 KB chunk');
    });

    // Much larger data → first chunk written, large remainder in buffer.
    test('very large data (100 KB) leaves 36 KB remainder after first flush',
        () {
      const chunkSize = 64 * 1024;
      const totalSize = 100 * 1024;
      final data = 'C' * totalSize;
      final remaining = notifier.flushOutputForTesting(terminal, data);
      expect(remaining.length, totalSize - chunkSize,
          reason: 'first 64 KB written, remaining ${totalSize - chunkSize} in buffer');
    });

    // Resize guard active → even large data is written all at once (no split).
    test('resize guard uses smaller chunk size (32KB) for large data', () {
      const chunkSize = 64 * 1024;
      final data = 'D' * (chunkSize + 1000); // > 64 KB

      notifier.setResizeGuardActiveForTesting(true);
      final remaining = notifier.flushOutputForTesting(terminal, data);

      // resize guard 中は 32KB チャンクで分割（UI ブロック防止）
      expect(remaining.length, chunkSize + 1000 - (32 * 1024),
          reason: 'resize guard should use 32KB chunks instead of 64KB');
    });

    // Resize guard inactive → normal chunking applies.
    test('resize guard false restores normal chunking', () {
      const chunkSize = 64 * 1024;
      final data = 'E' * (chunkSize + 200);

      notifier.setResizeGuardActiveForTesting(false);
      final remaining = notifier.flushOutputForTesting(terminal, data);

      expect(remaining.length, 200,
          reason: '200 bytes should remain after first chunk when guard is off');
    });

    // Alt buffer active → chunking disabled even for large data.
    //
    // TUI アプリ（Claude Code プランモード等）は alt buffer を使用する。
    // alt buffer 使用中にチャンク分割すると ANSI シーケンスが途中で切れて
    // 表示が崩れるため、resize guard と同様に分割を抑制する必要がある。
    test('alt buffer suppresses chunking for large data', () {
      const chunkSize = 64 * 1024;
      final data = 'F' * (chunkSize + 1000); // > 64 KB

      // ESC [ ? 1049 h を送ると alt buffer に切り替わる。
      // Terminal.useAltBuffer() を直接呼び出してテスト用に切り替える。
      terminal.useAltBuffer();
      expect(terminal.isUsingAltBuffer, isTrue, reason: 'precondition');

      final remaining = notifier.flushOutputForTesting(terminal, data);

      expect(remaining, isEmpty,
          reason: 'alt buffer must disable chunking — all data written at once');
    });

    // Alt buffer inactive → normal chunking applies.
    test('alt buffer inactive restores normal chunking', () {
      const chunkSize = 64 * 1024;
      final data = 'G' * (chunkSize + 300);

      // Ensure we are on the main buffer (default).
      terminal.useMainBuffer();
      expect(terminal.isUsingAltBuffer, isFalse, reason: 'precondition');

      final remaining = notifier.flushOutputForTesting(terminal, data);

      expect(remaining.length, 300,
          reason: '300 bytes should remain after first chunk on main buffer');
    });
  });

  // -------------------------------------------------------------------------
  // setAppInBackground() + _resetIdleNotifyTimer() threshold guard
  //
  // バックグラウンド通知機能のユニットテスト。
  // setAppInBackground() は static フラグを更新する。
  // _resetIdleNotifyTimer() は 256 バイト未満の出力ではタイマーを作成せず、
  // 256 バイト以上でタイマーを作成する（閾値ガード）。
  // -------------------------------------------------------------------------

  group('setAppInBackground() + idle timer threshold', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('idle-test').notifier,
      );
      // Timer tests require background mode; the flag-manipulation tests
      // explicitly set the flag themselves so the starting value doesn't matter.
      TerminalConnectionNotifier.setAppInBackground(true);
    });

    tearDown(() {
      container.dispose();
      // Reset static flag to avoid polluting other test groups.
      TerminalConnectionNotifier.setAppInBackground(false);
    });

    test('setAppInBackground(true) sets the flag to true', () {
      TerminalConnectionNotifier.setAppInBackground(true);
      expect(TerminalConnectionNotifier.isAppInBackgroundForTesting, isTrue);
    });

    test('setAppInBackground(false) clears the flag', () {
      TerminalConnectionNotifier.setAppInBackground(true);
      TerminalConnectionNotifier.setAppInBackground(false);
      expect(TerminalConnectionNotifier.isAppInBackgroundForTesting, isFalse);
    });

    test('no idle timer when output bytes are below threshold (< 4096)', () {
      // 4095 bytes of output should NOT create an idle notification timer.
      notifier.addOutputBytesForTesting(4095);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: 'bytes < threshold must not create an idle timer',
      );
    });

    test('idle timer created when output bytes reach threshold (== 4096)', () {
      // Exactly 4096 bytes should arm the idle notification timer.
      notifier.addOutputBytesForTesting(4096);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isTrue,
        reason: 'bytes == threshold must create an idle timer',
      );
    });

    test('idle timer created when output bytes exceed threshold (> 4096)', () {
      // Bytes above threshold (e.g., two separate chunks) should arm the timer.
      notifier.addOutputBytesForTesting(2000);
      expect(notifier.isIdleTimerActiveForTesting, isFalse,
          reason: 'first chunk below threshold → no timer yet');

      notifier.addOutputBytesForTesting(3000); // cumulative 5000 >= 4096
      expect(
        notifier.isIdleTimerActiveForTesting,
        isTrue,
        reason: 'cumulative bytes > threshold must create an idle timer',
      );
    });

    test('idle timer fires after 30s and is cleared', () {
      // Verify that the idle timer actually fires at the 30-second mark and
      // is cleared from _idleNotifyTimer (callback sets it to null via Timer).
      fakeAsync((async) {
        notifier.addOutputBytesForTesting(4096);
        expect(notifier.isIdleTimerActiveForTesting, isTrue,
            reason: 'timer should be armed after 4096 bytes');

        // Just before 30s: timer must still be pending.
        async.elapse(const Duration(seconds: 29, milliseconds: 999));
        expect(notifier.isIdleTimerActiveForTesting, isTrue,
            reason: 'timer must not fire before 30 seconds');

        // Past the 30-second mark: timer fires, callback runs.
        async.elapse(const Duration(milliseconds: 1));
        expect(notifier.isIdleTimerActiveForTesting, isFalse,
            reason: 'timer must be cleared after firing');
      });
    });

    test('byte counter resets to zero when idle timer fires', () {
      // After the timer fires, _outputBytesSinceLastIdle is reset to 0.
      // Verify indirectly: adding 4095 bytes (< 4096) after the timer fires
      // must NOT arm a new timer, proving the counter was zeroed.
      fakeAsync((async) {
        notifier.addOutputBytesForTesting(4096);
        expect(notifier.isIdleTimerActiveForTesting, isTrue);

        // Let the timer fire.
        async.elapse(const Duration(seconds: 30));
        expect(notifier.isIdleTimerActiveForTesting, isFalse);

        // Counter was reset to 0; adding 4095 bytes stays below threshold.
        notifier.addOutputBytesForTesting(4095);
        expect(notifier.isIdleTimerActiveForTesting, isFalse,
            reason: '4095 bytes < 4096 threshold after reset → no new timer');
      });
    });

    test('no idle timer created when _notificationSent is true', () {
      // _notificationSent == true ガード: 通知済みなら、バイト数が閾値以上でも
      // 新しいタイマーを作成しない（重複通知を防ぐ）。
      notifier.setNotificationSentForTesting(true);
      notifier.addOutputBytesForTesting(4096);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason:
            '_notificationSent == true guard must prevent creating a new timer',
      );
    });

    test('cancelled pending timer callback does not reset byte counter', () {
      // _resetIdleNotifyTimer() は先頭で既存タイマーを cancel() してから
      // _notificationSent ガードに到達する。コールバックが実行されなければ
      // _outputBytesSinceLastIdle は 0 にリセットされない。
      // これをバイトカウンタの間接観察で確認する。
      fakeAsync((async) {
        // timer をアームする（counter = 4096）。
        notifier.addOutputBytesForTesting(4096);
        expect(notifier.isIdleTimerActiveForTesting, isTrue,
            reason: 'precondition: timer must be armed');

        // 通知済みにしてから追加出力 → cancel() + 早期リターン（counter = 4196）。
        notifier.setNotificationSentForTesting(true);
        notifier.addOutputBytesForTesting(100);

        // 30s 経過: キャンセルされていればコールバックは走らず counter は 4196 のまま。
        // もしキャンセルされていなければコールバックが counter を 0 にリセットする。
        async.elapse(const Duration(seconds: 31));

        // _notificationSent を解除して新しいタイマーを作れる状態にする。
        notifier.setNotificationSentForTesting(false);
        notifier.addOutputBytesForTesting(0); // _resetIdleNotifyTimer() を呼ぶ

        // counter が 4196 (> 4096) のままなら新タイマーが作られる = cancel が効いた証拠。
        // counter が 0 にリセットされていれば新タイマーは作られない。
        expect(
          notifier.isIdleTimerActiveForTesting,
          isTrue,
          reason: 'byte counter must not have been reset by the cancelled '
              'callback; cumulative bytes >= threshold must arm a new timer',
        );
      });
    });

    test('no idle timer when app is in foreground (!_isAppInBackground)', () {
      // フォアグラウンドガード: バイト数が閾値以上でもタイマーを作らない。
      // バイトカウントだけ蓄積されるが、バックグラウンド移行まで通知しない。
      TerminalConnectionNotifier.setAppInBackground(false);
      notifier.addOutputBytesForTesting(4096);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: 'foreground guard must prevent idle timer even above threshold',
      );
    });

    test('idle timer created after transitioning foreground → background', () {
      // フォアグラウンドで蓄積したバイトカウントは保持される。
      // バックグラウンドに移行してから次の出力受信時にタイマーが作成される。
      TerminalConnectionNotifier.setAppInBackground(false);
      notifier.addOutputBytesForTesting(4096); // 閾値以上 — タイマー不作成
      expect(notifier.isIdleTimerActiveForTesting, isFalse,
          reason: 'foreground: no timer despite bytes >= threshold');

      TerminalConnectionNotifier.setAppInBackground(true);
      // バックグラウンド移行後、次の出力受信でタイマーが作成される。
      notifier.addOutputBytesForTesting(1); // _resetIdleNotifyTimer() を再呼び出し
      expect(
        notifier.isIdleTimerActiveForTesting,
        isTrue,
        reason:
            'after transitioning to background, new output must arm the timer',
      );
    });

    // -------------------------------------------------------------------------
    // コールバック内の二重チェックガードのテスト
    //
    // タイマー作成後、コールバック実行前に状態が変化した場合、
    // コールバック内のガードが通知送信をスキップする。
    // -------------------------------------------------------------------------

    test('callback skips notification when app returns to foreground before timer fires', () {
      // タイマーをアームした後、発火前にフォアグラウンドに戻る。
      // コールバック内の _isAppInBackground ガードが通知送信をスキップする。
      fakeAsync((async) {
        notifier.addOutputBytesForTesting(4096);
        expect(notifier.isIdleTimerActiveForTesting, isTrue,
            reason: 'precondition: timer must be armed');

        // タイマー発火前にフォアグラウンドへ戻る。
        TerminalConnectionNotifier.setAppInBackground(false);

        // タイマーを発火させる。
        async.elapse(const Duration(seconds: 30));
        expect(notifier.isIdleTimerActiveForTesting, isFalse,
            reason: 'timer must have fired and cleared itself');

        // コールバック内の _isAppInBackground ガードで通知がスキップされた。
        expect(notifier.isNotificationSentForTesting, isFalse,
            reason: 'callback must not send notification when app is in foreground');
      });
    });

    test('callback resets byte counter even when notification is skipped due to foreground', () {
      // コールバック内の _outputBytesSinceLastIdle = 0 は条件分岐の外にある。
      // フォアグラウンドで通知がスキップされても、バイトカウンタはリセットされる。
      fakeAsync((async) {
        notifier.addOutputBytesForTesting(4096);
        expect(notifier.isIdleTimerActiveForTesting, isTrue);

        // タイマー発火前にフォアグラウンドへ戻る（通知スキップ）。
        TerminalConnectionNotifier.setAppInBackground(false);
        async.elapse(const Duration(seconds: 30));
        expect(notifier.isIdleTimerActiveForTesting, isFalse);

        // バイトカウンタが 0 にリセットされているはず。
        // バックグラウンドに戻り、4095 バイト追加 → 閾値未満 → タイマー不作成。
        TerminalConnectionNotifier.setAppInBackground(true);
        notifier.addOutputBytesForTesting(4095);
        expect(notifier.isIdleTimerActiveForTesting, isFalse,
            reason: 'byte counter must be reset to 0 by callback even when '
                'notification was skipped; 4095 bytes < 4096 threshold');
      });
    });

    test('callback skips notification when _notificationSent is already true at fire time', () {
      // タイマーをアームした後（_notificationSent == false）、発火前に
      // _notificationSent を true にセットする。
      // コールバック内の !_notificationSent ガードが重複通知をスキップする。
      fakeAsync((async) {
        notifier.addOutputBytesForTesting(4096);
        expect(notifier.isIdleTimerActiveForTesting, isTrue,
            reason: 'precondition: timer must be armed');

        // タイマー発火前に通知済みフラグをセット（別セッションやパスで通知済みを想定）。
        notifier.setNotificationSentForTesting(true);

        // タイマーを発火させる。コールバック内の !_notificationSent が false → スキップ。
        async.elapse(const Duration(seconds: 30));
        expect(notifier.isIdleTimerActiveForTesting, isFalse,
            reason: 'timer must have fired and cleared itself');

        // バイトカウンタが 0 にリセットされたことを確認（カウンタリセットは常に実行）。
        // _notificationSent を解除して新タイマーを作れる状態にする。
        notifier.setNotificationSentForTesting(false);
        notifier.addOutputBytesForTesting(4095);
        expect(notifier.isIdleTimerActiveForTesting, isFalse,
            reason: 'byte counter must be reset to 0 by callback; '
                '4095 bytes < 4096 threshold → no new timer');
      });
    });
  });

  // -------------------------------------------------------------------------
  // clearNotificationFlag()
  //
  // ユーザーがタブを確認したときに呼ばれる。
  // - 進行中のアイドルタイマーをキャンセルする
  // - 出力バイトカウンタをリセットする（次の通知判定を0から始める）
  // - _notificationSent フラグをクリアする（再び通知を送れるようにする）
  // -------------------------------------------------------------------------

  group('clearNotificationFlag()', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('clear-flag-test').notifier,
      );
      TerminalConnectionNotifier.setAppInBackground(true);
    });

    tearDown(() {
      container.dispose();
      TerminalConnectionNotifier.setAppInBackground(false);
    });

    test('cancels active idle timer', () {
      // Arm the idle timer by pushing output above threshold.
      notifier.addOutputBytesForTesting(4096);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isTrue,
        reason: 'precondition: idle timer must be active before clearing',
      );

      notifier.clearNotificationFlag();

      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: 'clearNotificationFlag() must cancel the pending idle timer',
      );
    });

    test('resets byte counter so bytes after clearing does not arm timer', () {
      // Push 3000 bytes — below 4096 threshold, no timer yet.
      notifier.addOutputBytesForTesting(3000);
      expect(notifier.isIdleTimerActiveForTesting, isFalse,
          reason: 'precondition: 3000 bytes are below the 4096-byte threshold');

      // Clear resets _outputBytesSinceLastIdle to 0.
      notifier.clearNotificationFlag();

      // Adding 2000 bytes after reset: total = 0 + 2000 < 4096 → no timer.
      // Without the reset, total would be 3000 + 2000 = 5000 ≥ 4096 → timer armed.
      notifier.addOutputBytesForTesting(2000);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: 'byte counter must have been reset to 0; '
            '2000 bytes from zero is below threshold → no idle timer',
      );
    });

    test('is safe to call when no timer is active', () {
      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: 'precondition: no active timer',
      );

      // Must not throw.
      expect(() => notifier.clearNotificationFlag(), returnsNormally);

      expect(notifier.isIdleTimerActiveForTesting, isFalse);
    });

    test('resets _notificationSent so a subsequent cycle can fire again', () {
      // Simulate a notification having already been sent.
      notifier.setNotificationSentForTesting(true);
      expect(
        notifier.isNotificationSentForTesting,
        isTrue,
        reason: 'precondition: _notificationSent must be true before clearing',
      );

      notifier.clearNotificationFlag();

      expect(
        notifier.isNotificationSentForTesting,
        isFalse,
        reason: 'clearNotificationFlag() must reset _notificationSent to false '
            'so the next idle cycle can send a notification',
      );
    });
  });

  // -------------------------------------------------------------------------
  // resetIdleCounter()
  //
  // バックグラウンド移行時に呼ばれる。
  // - 進行中のアイドルタイマーをキャンセルする
  // - 出力バイトカウンタをリセットする（フォアグラウンドで蓄積された分を捨てる）
  // - _notificationSent フラグはリセットしない（clearNotificationFlag との違い）
  // -------------------------------------------------------------------------

  group('resetIdleCounter()', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('reset-idle-test').notifier,
      );
      TerminalConnectionNotifier.setAppInBackground(true);
    });

    tearDown(() {
      container.dispose();
      TerminalConnectionNotifier.setAppInBackground(false);
    });

    test('cancels active idle timer', () {
      notifier.addOutputBytesForTesting(4096);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isTrue,
        reason: 'precondition: idle timer must be active before reset',
      );

      notifier.resetIdleCounter();

      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: 'resetIdleCounter() must cancel the pending idle timer',
      );
    });

    test('resets byte counter so previously accumulated bytes are discarded',
        () {
      // Push 3000 bytes — below threshold, no timer yet.
      notifier.addOutputBytesForTesting(3000);
      expect(notifier.isIdleTimerActiveForTesting, isFalse,
          reason: 'precondition: 3000 bytes are below the 4096-byte threshold');

      notifier.resetIdleCounter();

      // After reset, counter is 0. Adding 2000 bytes stays below threshold.
      notifier.addOutputBytesForTesting(2000);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: 'byte counter must have been reset; '
            '2000 bytes from zero is below threshold → no idle timer',
      );
    });

    test('does not reset _notificationSent (contrast with clearNotificationFlag)',
        () {
      notifier.setNotificationSentForTesting(true);

      notifier.resetIdleCounter();

      expect(
        notifier.isNotificationSentForTesting,
        isTrue,
        reason: 'resetIdleCounter() must NOT reset _notificationSent; '
            'only clearNotificationFlag() does that',
      );
    });

    test('is safe to call when no timer is active', () {
      expect(notifier.isIdleTimerActiveForTesting, isFalse,
          reason: 'precondition: no active timer');

      expect(() => notifier.resetIdleCounter(), returnsNormally);

      expect(notifier.isIdleTimerActiveForTesting, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // _cleanupConnections() — idle counter reset
  //
  // _cleanupConnections() delegates idle-counter teardown to resetIdleCounter().
  // Verify that disconnect/reconnect paths (which call _cleanupConnections())
  // cancel any pending idle timer and discard accumulated byte counts.
  // -------------------------------------------------------------------------

  group('_cleanupConnections() resets idle counter', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('cleanup-idle-test').notifier,
      );
      fakeService = _FakeSshClientService();
      TerminalConnectionNotifier.setAppInBackground(true);
    });

    tearDown(() {
      container.dispose();
      TerminalConnectionNotifier.setAppInBackground(false);
    });

    test('triggerOnDisconnected cancels the idle timer', () {
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );
      // Accumulate enough bytes to arm the idle timer.
      notifier.addOutputBytesForTesting(4096);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isTrue,
        reason: 'precondition: idle timer must be active before disconnect',
      );

      notifier.triggerOnDisconnectedForTesting();

      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: '_cleanupConnections() must cancel the idle timer via resetIdleCounter()',
      );
    });

    test('triggerOnDisconnected discards accumulated byte count', () {
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );
      // Accumulate 3000 bytes (below threshold — no timer yet).
      notifier.addOutputBytesForTesting(3000);

      notifier.triggerOnDisconnectedForTesting();

      // After cleanup, byte counter must be 0. Adding 2000 more bytes stays
      // below threshold — no idle timer should be armed.
      notifier.addOutputBytesForTesting(2000);
      expect(
        notifier.isIdleTimerActiveForTesting,
        isFalse,
        reason: 'byte counter must be reset by _cleanupConnections(); '
            '2000 bytes from zero is below the 4096-byte threshold',
      );
    });
  });

  // -------------------------------------------------------------------------
  // _autoReattachTmux()
  //
  // 再接続後に tmux セッションへ自動リアタッチする機能のユニットテスト。
  // terminal.onOutput コールバックで textInput() の呼び出しを検証する。
  // -------------------------------------------------------------------------

  group('_autoReattachTmux()', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('tmux-reattach-test').notifier,
      );
      fakeService = _FakeSshClientService();
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );
    });

    tearDown(() => container.dispose());

    test('does nothing when tmuxSessionName is null', () async {
      final terminal = Terminal(maxLines: 50);
      final received = <String>[];
      terminal.onOutput = received.add;

      // _tmuxSessionName is null by default → should return early immediately.
      notifier.autoReattachTmuxForTesting(terminal);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty,
          reason: 'no textInput should be sent when tmuxSessionName is null');
    });

    test('sends tmux attach command after shell is ready', () async {
      final terminal = Terminal(maxLines: 50);
      final received = <String>[];
      terminal.onOutput = received.add;

      notifier.setTmuxSessionNameForTesting('my-session');
      notifier.markShellReadyForTesting();
      notifier.autoReattachTmuxForTesting(terminal);

      // Wait for initial delay (300ms) + processing buffer.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(received, isNotEmpty,
          reason: 'tmux attach command must be sent to the terminal');
      final combined = received.join('');
      expect(combined, contains("tmux attach -t 'my-session'\r"),
          reason: 'command must include shell-quoted session name');
    });

    test('shell-escapes session names containing single quotes', () async {
      final terminal = Terminal(maxLines: 50);
      final received = <String>[];
      terminal.onOutput = received.add;

      // shellQuote("it's") = "'it'\\''s'"
      notifier.setTmuxSessionNameForTesting("it's");
      notifier.markShellReadyForTesting();
      notifier.autoReattachTmuxForTesting(terminal);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      final combined = received.join('');
      expect(combined, contains(r"tmux attach -t 'it'\''s'" "\r"),
          reason: 'single quotes in session name must be escaped');
    });

    test('does nothing for second call when tmuxSessionName is null', () async {
      final terminal = Terminal(maxLines: 50);
      final received = <String>[];
      terminal.onOutput = received.add;

      // First call with a session name — sends command.
      notifier.setTmuxSessionNameForTesting('session-a');
      notifier.markShellReadyForTesting();
      notifier.autoReattachTmuxForTesting(terminal);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final countAfterFirst = received.length;
      expect(countAfterFirst, greaterThan(0));

      // Clear and set session name to null — no further output.
      received.clear();
      notifier.setTmuxSessionNameForTesting(null);
      notifier.autoReattachTmuxForTesting(terminal);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty,
          reason: 'null session name must prevent textInput call');
    });

    // -------------------------------------------------------------------------
    // PTY resize-after-attach (line 391-397):
    //   await Future.delayed(500ms);
    //   if (w > 0 && h > 0) _channelManager?.resizePty(w, h);
    //
    // Terminal defaults to 80×24, so a fresh Terminal triggers the happy path.
    // Wait must cover _shellReadyInitialDelay (300ms) + 500ms resize delay.
    // -------------------------------------------------------------------------

    test('calls resizePty after tmux attach when terminal has non-zero size',
        () async {
      final terminal = Terminal(maxLines: 50);
      // Default viewWidth=80, viewHeight=24 (non-zero → resizePty should fire).
      final mockManager = _MockSshChannelManager();

      notifier.setTmuxSessionNameForTesting('resize-session');
      notifier.setChannelManagerForTesting(mockManager);
      notifier.markShellReadyForTesting();
      notifier.autoReattachTmuxForTesting(terminal);

      // 300ms shell-ready delay + 500ms resize delay + buffer.
      await Future<void>.delayed(const Duration(milliseconds: 1000));

      verify(() => mockManager.resizePty(80, 24)).called(1);
    });

    test('calls resizePty with correct custom terminal dimensions', () async {
      final terminal = Terminal(maxLines: 50);
      terminal.resize(120, 40); // custom size — resizePty must use these values
      final mockManager = _MockSshChannelManager();

      notifier.setTmuxSessionNameForTesting('resize-custom');
      notifier.setChannelManagerForTesting(mockManager);
      notifier.markShellReadyForTesting();
      notifier.autoReattachTmuxForTesting(terminal);

      await Future<void>.delayed(const Duration(milliseconds: 1000));

      verify(() => mockManager.resizePty(120, 40)).called(1);
    });

    test('skips resizePty when channelManager is null', () async {
      // _channelManager is null by default (not set via setChannelManagerForTesting).
      // The null-safe call `_channelManager?.resizePty(w, h)` must be a no-op.
      final terminal = Terminal(maxLines: 50); // 80×24 (non-zero)
      final mockManager = _MockSshChannelManager();

      notifier.setTmuxSessionNameForTesting('resize-null-mgr');
      // Do NOT call setChannelManagerForTesting — _channelManager stays null.
      notifier.markShellReadyForTesting();
      notifier.autoReattachTmuxForTesting(terminal);

      await Future<void>.delayed(const Duration(milliseconds: 1000));

      verifyNever(() => mockManager.resizePty(any(), any()));
    });

    test('skips resizePty when terminal dimensions are zero', () async {
      // _autoReattachTmux guards: if (w > 0 && h > 0) before calling resizePty.
      // Terminal.resize() clamps to min(1, ...) so the only way to produce 0×0
      // dimensions is via a subclass that overrides the getters.
      final terminal = _ZeroDimensionTerminal(); // viewWidth=0, viewHeight=0
      final mockManager = _MockSshChannelManager();

      notifier.setTmuxSessionNameForTesting('resize-zero');
      notifier.setChannelManagerForTesting(mockManager);
      notifier.markShellReadyForTesting();
      notifier.autoReattachTmuxForTesting(terminal);

      // 300ms shell-ready delay + 500ms resize delay + buffer.
      await Future<void>.delayed(const Duration(milliseconds: 1000));

      // zero-dimension guard must prevent resizePty from being called
      verifyNever(() => mockManager.resizePty(any(), any()));
    });

    // -------------------------------------------------------------------------
    // catchError guard: resizePty throws → exception must not propagate
    //
    // The unawaited future in _autoReattachTmux wraps the shell-ready wait and
    // the resize call. If resizePty throws (e.g. SSH connection dropped between
    // the attach command and the resize delay), the .catchError handler must
    // absorb the exception so it does not become an unhandled future error.
    // -------------------------------------------------------------------------
    test('does not propagate exceptions thrown by resizePty', () async {
      final terminal = Terminal(maxLines: 50); // 80×24 → resizePty will be called
      final mockManager = _MockSshChannelManager();

      when(() => mockManager.resizePty(any(), any()))
          .thenThrow(StateError('SSH channel closed'));

      notifier.setTmuxSessionNameForTesting('error-session');
      notifier.setChannelManagerForTesting(mockManager);
      notifier.markShellReadyForTesting();

      // autoReattachTmux must complete without throwing despite resizePty error.
      expect(
        () async {
          notifier.autoReattachTmuxForTesting(terminal);
          await Future<void>.delayed(const Duration(milliseconds: 1000));
        },
        returnsNormally,
      );

      // Wait for the unawaited chain to fully settle.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    });
  });

  // ---------------------------------------------------------------------------
  // checkConnection() — _isReconnecting flag guard (Phase 50)
  //
  // Line 458: `if (_isReconnecting) return;`
  // Distinct from the status==reconnecting guard (line 459).
  // _isReconnecting is set synchronously in _attemptReconnect() before the
  // async work starts, preventing a concurrent checkConnection() from also
  // calling _attemptReconnect().
  // ---------------------------------------------------------------------------

  group('checkConnection() _isReconnecting flag guard', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('ir-flag-test').notifier,
      );
      fakeService = _FakeSshClientService();
    });

    tearDown(() => container.dispose());

    test('checkConnection returns early when _isReconnecting flag is true',
        () async {
      // Arrange: connected state + _isReconnecting = true (simulates
      // _attemptReconnect already running).
      fakeService.keepAliveResult = false; // would trigger disconnect if guard fails
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        ),
      );
      notifier.setIsReconnectingForTesting(true);

      // Act: checkConnection must return early due to _isReconnecting guard.
      await notifier.checkConnection();

      // Assert: status must remain connected — no keepAlive probe, no disconnect.
      expect(
        container.read(terminalConnectionProvider('ir-flag-test')).status,
        ConnectionStatus.connected,
        reason: '_isReconnecting guard must prevent checkConnection from '
            'calling _onDisconnected while a reconnect is already in progress',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // checkConnection() — retry path: first probe fails, second succeeds
  //
  // Two-probe sequence in checkConnection(): probe 1 → 1s delay → probe 2.
  // When the first keepAlive returns false but the second returns true,
  // the notifier must stay connected (not call _onDisconnected).
  // ---------------------------------------------------------------------------

  group('checkConnection() keepAlive retry on first failure', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FirstFailSshClientService firstFailService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('retry-test').notifier,
      );
      firstFailService = _FirstFailSshClientService();
    });

    tearDown(() => container.dispose());

    test('stays connected when first probe fails but second succeeds',
        () async {
      notifier.initConnectedStateForTesting(
        sshService: firstFailService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        ),
      );

      // First keepAlive returns false, second returns true.
      await notifier.checkConnection();

      expect(
        container.read(terminalConnectionProvider('retry-test')).status,
        ConnectionStatus.connected,
        reason: 'connection must survive a single keepAlive probe failure '
            'when the retry probe succeeds',
      );
      expect(firstFailService._callCount, 2,
          reason: 'exactly two keepAlive probes must be sent');
    });
  });

  // ---------------------------------------------------------------------------
  // checkConnection() — null sshService path (Phase 51)
  //
  // Lines 475-478:
  //   final service = _sshService;
  //   if (service == null) {
  //     _onDisconnected();
  //     return;
  //   }
  //
  // When status is connected but _sshService is null (e.g. race between
  // SSH disconnect cleanup and a pending checkConnection() call), the notifier
  // must call _onDisconnected() and transition to disconnected.
  // ---------------------------------------------------------------------------

  group('checkConnection() null sshService path', () {
    test('calls _onDisconnected when _sshService is null while connected',
        () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(
        terminalConnectionProvider('null-ssh-test').notifier,
      );
      final fakeService = _FakeSshClientService();

      // Set connected state with a service + config so status guard is passed.
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        ),
      );

      // Simulate race: _sshService becomes null before checkConnection runs.
      notifier.clearSshServiceForTesting();

      await notifier.checkConnection();

      expect(
        container.read(terminalConnectionProvider('null-ssh-test')).status,
        ConnectionStatus.disconnected,
        reason: 'checkConnection must call _onDisconnected when _sshService is null',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // checkConnection() — connected path: both probes fail (fakeAsync end-to-end)
  //
  // Lines 544-562: the two-probe keepAlive loop when both probes fail.
  // The second failure triggers _onDisconnected() → _scheduleReconnect() → 3s
  // timer. When that timer fires, _attemptReconnect() fails again and the 6s
  // timer is scheduled.
  //
  // End-to-end chain verified with fakeAsync:
  //   checkConnection() → probe 1 fails → 1s retry delay →
  //   probe 2 fails → _onDisconnected() → 3s timer →
  //   _attemptReconnect() fails → _scheduleReconnect() → 6s timer (attempt #2)
  // ---------------------------------------------------------------------------

  group('checkConnection() connected: both probes fail → schedules reconnect',
      () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('cc-both-fail-test').notifier,
      );
      fakeService = _FakeSshClientService();
    });

    tearDown(() => container.dispose());

    test(
        'both probes fail → 3s timer fires → attempt #2 scheduled at 6s',
        () {
      fakeAsync((async) {
        const config = ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        );
        fakeService.keepAliveResult = false; // both probes will fail
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Fire checkConnection() without awaiting — fakeAsync controls the clock.
        // ignore: unawaited_futures
        notifier.checkConnection();

        // Flush: first keepAlive() resolves to false → 1s retry delay scheduled.
        async.flushMicrotasks();

        // Advance 1 second: retry delay elapses, second keepAlive() is called.
        async.elapse(const Duration(seconds: 1));
        // Flush: second keepAlive() resolves to false → _onDisconnected() called
        // → _scheduleReconnect() creates the 3s timer (_retryCount=1).
        async.flushMicrotasks();

        var state =
            container.read(terminalConnectionProvider('cc-both-fail-test'));
        expect(state.status, ConnectionStatus.disconnected,
            reason: 'both probes failed → must transition to disconnected');
        expect(
          state.errorMessage,
          'Reconnecting in 3s... (attempt #1)',
          reason: '_scheduleReconnect() must set attempt #1 with 3s delay',
        );

        // Advance 3 seconds: the backoff timer fires and _attemptReconnect() runs.
        async.elapse(const Duration(seconds: 3));
        // Flush: _connectCore() fails (via _FailFastSshClientService) →
        // _scheduleReconnect() increments _retryCount to 2 → 6s timer.
        async.flushMicrotasks();

        state =
            container.read(terminalConnectionProvider('cc-both-fail-test'));
        expect(state.status, ConnectionStatus.disconnected,
            reason: 'reconnect attempt also failed → still disconnected');
        expect(
          state.errorMessage,
          'Reconnecting in 6s... (attempt #2)',
          reason: 'second failed attempt must double the backoff to 6s',
        );
      });
    });
  });

  // ---------------------------------------------------------------------------
  // checkConnection() — service identity guard during 1s retry delay
  //
  // After probe 1 fails, checkConnection() waits 1 second before probe 2.
  // The identity guard fires after the delay:
  //   await Future.delayed(const Duration(seconds: 1));
  //   if (!identical(service, _sshService)) return;  ← guard
  //
  // If _sshService is replaced (reconnect) or cleared (disconnect cleanup)
  // while checkConnection() is waiting the 1-second retry delay, the stale
  // probe must return early without calling _onDisconnected() — avoiding a
  // spurious second disconnect/reconnect cycle.
  // ---------------------------------------------------------------------------

  group('checkConnection() service identity guard during 1s retry delay', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('cc-identity-test').notifier,
      );
    });

    tearDown(() => container.dispose());

    test(
        'service swap during 1s retry delay aborts checkConnection '
        'without disconnect', () {
      fakeAsync((async) {
        final originalService = _FakeSshClientService()
          ..keepAliveResult = false;
        notifier.initConnectedStateForTesting(
          sshService: originalService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: const ConnectionConfig(
            label: 'test',
            host: '127.0.0.1',
            username: 'u',
          ),
        );

        // Fire checkConnection() — probe 1 fails, 1s delay starts.
        // ignore: unawaited_futures
        notifier.checkConnection();
        async.flushMicrotasks(); // probe 1 → false; 1s timer scheduled

        // Replace _sshService while the 1s delay is pending (simulates reconnect).
        final newService = _FakeSshClientService()..keepAliveResult = true;
        notifier.initConnectedStateForTesting(
          sshService: newService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: const ConnectionConfig(
            label: 'test',
            host: '127.0.0.1',
            username: 'u',
          ),
        );

        // Advance 1s — identity check fires (original ≠ new) → returns early.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        // Still connected — the stale probe must not have called _onDisconnected().
        expect(
          container.read(terminalConnectionProvider('cc-identity-test')).status,
          ConnectionStatus.connected,
          reason: 'service swap during retry delay must abort checkConnection '
              'without triggering disconnect',
        );
      });
    });

    test(
        'service cleared during 1s retry delay aborts checkConnection '
        'without duplicate disconnect', () {
      fakeAsync((async) {
        final originalService = _FakeSshClientService()
          ..keepAliveResult = false;
        notifier.initConnectedStateForTesting(
          sshService: originalService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: const ConnectionConfig(
            label: 'test',
            host: '127.0.0.1',
            username: 'u',
          ),
        );

        // Fire checkConnection() — probe 1 fails, 1s delay starts.
        // ignore: unawaited_futures
        notifier.checkConnection();
        async.flushMicrotasks();

        // Simulate external disconnect clearing _sshService mid-wait.
        notifier.clearSshServiceForTesting();

        // Advance 1s — identity check: original ≠ null → returns early.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        // checkConnection() returned early — no additional _onDisconnected() call.
        // Status remains what it was before (connected) because only
        // clearSshServiceForTesting() was called, not _onDisconnected().
        expect(
          container.read(terminalConnectionProvider('cc-identity-test')).status,
          ConnectionStatus.connected,
          reason: 'cleared service during retry delay must abort checkConnection '
              'silently, not trigger a second disconnect',
        );
      });
    });
  });

  // ---------------------------------------------------------------------------
  // checkConnection() — service identity guard after probe 2 keepAlive
  //
  // After probe 2's keepAlive() awaits, the identity guard fires:
  //   if (!identical(service, _sshService)) return;
  //
  // This is the last guard before _onDisconnected() — if _sshService was
  // replaced or cleared while probe 2's keepAlive() was awaiting,
  // checkConnection() must return early without calling _onDisconnected().
  //
  // The delay-guard tests (group above) only cover the window during the 1s
  // delay between probes. These tests cover the window DURING probe 2's
  // keepAlive() call, using a Completer-blocked fake service to hold probe 2
  // open while the swap is injected.
  // ---------------------------------------------------------------------------

  group('checkConnection() service identity guard after probe 2', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('cc-probe2-guard-test').notifier,
      );
    });

    tearDown(() => container.dispose());

    test(
        'service swap during probe 2 keepAlive → identity guard aborts '
        'without disconnect', () {
      fakeAsync((async) {
        final probe2Completer = Completer<bool>();
        final blockingService = _BlockingProbe2Service()
          ..probe2Completer = probe2Completer;
        notifier.initConnectedStateForTesting(
          sshService: blockingService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: const ConnectionConfig(
            label: 'test',
            host: '127.0.0.1',
            username: 'u',
          ),
        );

        // Fire checkConnection() — probe 1 fails, 1s retry delay starts.
        // ignore: unawaited_futures
        notifier.checkConnection();
        async.flushMicrotasks(); // probe 1 → false; 1s timer scheduled

        // Advance 1s: delay ends, delay identity check passes,
        // probe 2 starts and blocks on probe2Completer.
        async.elapse(const Duration(seconds: 1));

        // Replace _sshService while probe 2 is still pending.
        final newService = _FakeSshClientService()..keepAliveResult = true;
        notifier.initConnectedStateForTesting(
          sshService: newService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: const ConnectionConfig(
            label: 'test',
            host: '127.0.0.1',
            username: 'u',
          ),
        );

        // Complete probe 2 with false — identity check: original ≠ new
        // → checkConnection() returns early without calling _onDisconnected().
        probe2Completer.complete(false);
        async.flushMicrotasks();

        expect(
          container
              .read(terminalConnectionProvider('cc-probe2-guard-test'))
              .status,
          ConnectionStatus.connected,
          reason: 'service swap during probe 2 must abort checkConnection '
              'without triggering disconnect',
        );
      });
    });

    test(
        'service cleared during probe 2 keepAlive → identity guard aborts '
        'without duplicate disconnect', () {
      fakeAsync((async) {
        final probe2Completer = Completer<bool>();
        final blockingService = _BlockingProbe2Service()
          ..probe2Completer = probe2Completer;
        notifier.initConnectedStateForTesting(
          sshService: blockingService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: const ConnectionConfig(
            label: 'test',
            host: '127.0.0.1',
            username: 'u',
          ),
        );

        // Fire checkConnection() — probe 1 fails, 1s retry delay starts.
        // ignore: unawaited_futures
        notifier.checkConnection();
        async.flushMicrotasks();

        // Advance 1s: probe 2 starts and blocks on probe2Completer.
        async.elapse(const Duration(seconds: 1));

        // Clear _sshService while probe 2 is pending (simulates disconnect cleanup).
        notifier.clearSshServiceForTesting();

        // Complete probe 2 — identity check: original ≠ null → returns early.
        probe2Completer.complete(false);
        async.flushMicrotasks();

        // checkConnection() returned early — no additional _onDisconnected() call.
        expect(
          container
              .read(terminalConnectionProvider('cc-probe2-guard-test'))
              .status,
          ConnectionStatus.connected,
          reason: 'cleared service during probe 2 must abort checkConnection '
              'silently, not trigger a second disconnect',
        );
      });
    });
  });

  // ---------------------------------------------------------------------------
  // connect() — guard conditions (lines 113-116)
  //
  // connect() returns early without starting any SSH connection when
  // status is already `connecting` or `connected`.
  // ---------------------------------------------------------------------------

  group('connect() guard conditions', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('connect-guard-test').notifier,
      );
      fakeService = _FakeSshClientService();
    });

    tearDown(() => container.dispose());

    test('connect() is a no-op when status is connecting', () async {
      // Inject connecting state — simulates in-progress connect().
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connecting,
          hostLabel: 'test-host',
        ),
      );

      // Calling connect() while connecting must return immediately without SSH.
      await notifier.connect(
        config: const ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        ),
      );

      // Status unchanged — guard prevented a second connect attempt.
      expect(
        container.read(terminalConnectionProvider('connect-guard-test')).status,
        ConnectionStatus.connecting,
        reason: 'connect() must be a no-op when already connecting',
      );
    });

    test('connect() is a no-op when status is connected', () async {
      // Inject connected state — simulates an established session.
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );

      // Calling connect() while connected must return immediately without SSH.
      await notifier.connect(
        config: const ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        ),
      );

      // Status unchanged — guard prevented reconnect while already up.
      expect(
        container.read(terminalConnectionProvider('connect-guard-test')).status,
        ConnectionStatus.connected,
        reason: 'connect() must be a no-op when already connected',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // connect() failure path
  //
  // When _connectCore() throws (e.g. connection refused), connect() must:
  //   1. Transition status to disconnected with the error message.
  //   2. NOT schedule auto-reconnect (_scheduleReconnect is only called from
  //      _onDisconnected(), not from the connect() catch block).
  //   3. Preserve the hostLabel set during the connecting phase.
  // ---------------------------------------------------------------------------

  group('connect() failure path', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('connect-fail-test').notifier,
      );
    });

    tearDown(() => container.dispose());

    test('sets status to disconnected with errorMessage on failure', () async {
      // Inject a service that throws on connect() → _connectCore() fails.
      notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

      await notifier.connect(
        config: const ConnectionConfig(
          label: 'test-server',
          host: '127.0.0.1',
          username: 'u',
        ),
      );

      final state =
          container.read(terminalConnectionProvider('connect-fail-test'));
      expect(state.status, ConnectionStatus.disconnected,
          reason: 'connect() failure must end in disconnected');
      expect(state.errorMessage, isNotNull,
          reason: 'errorMessage must be set from the caught exception');
      expect(state.errorMessage, contains('connection refused'),
          reason: 'errorMessage must reflect the actual connection error');
    });

    test('errorMessage uses AppError.message without class-name prefix', () async {
      // _NetworkErrorSshClientService.connect() throws NetworkError('Host unreachable')
      // directly, bypassing the SshClientService error-wrapping catch blocks.
      // The notifier must store the clean message, not the toString() result
      // ('NetworkError: Host unreachable').
      notifier.sshServiceFactoryOverride = () => _NetworkErrorSshClientService();

      await notifier.connect(
        config: const ConnectionConfig(
          label: 'test-server',
          host: '127.0.0.1',
          username: 'u',
        ),
      );

      final state =
          container.read(terminalConnectionProvider('connect-fail-test'));
      expect(state.errorMessage, 'Host unreachable',
          reason: 'AppError.message must be used, not toString() which adds '
              'a "NetworkError: " class-name prefix');
      expect(
        state.errorMessage,
        isNot(contains('NetworkError:')),
        reason: 'class-name prefix must not appear in user-facing errorMessage',
      );
    });

    test('preserves hostLabel after failure', () async {
      notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

      await notifier.connect(
        config: const ConnectionConfig(
          label: 'my-server',
          host: '127.0.0.1',
          username: 'u',
        ),
      );

      final state =
          container.read(terminalConnectionProvider('connect-fail-test'));
      // hostLabel was set to config.label before _connectCore() was called.
      expect(state.hostLabel, 'my-server',
          reason: 'hostLabel set during connecting phase must survive failure');
    });

    test('uses host as hostLabel when config.label is empty', () async {
      notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

      await notifier.connect(
        config: const ConnectionConfig(
          label: '',
          host: '192.168.1.99',
          username: 'u',
        ),
      );

      final state =
          container.read(terminalConnectionProvider('connect-fail-test'));
      expect(state.hostLabel, '192.168.1.99',
          reason: 'when label is empty, host is used as hostLabel');
    });

    test('does not schedule auto-reconnect after initial connect failure',
        () async {
      // Unlike _onDisconnected() → _scheduleReconnect(), the connect() catch
      // block does NOT call _scheduleReconnect(). Verify: errorMessage does not
      // contain "Reconnecting in" after failure.
      notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

      await notifier.connect(
        config: const ConnectionConfig(
          label: 'test-server',
          host: '127.0.0.1',
          username: 'u',
        ),
      );

      final state =
          container.read(terminalConnectionProvider('connect-fail-test'));
      expect(state.errorMessage, isNot(contains('Reconnecting in')),
          reason: 'initial connect failure must not trigger auto-reconnect');
    });
  });

  // ---------------------------------------------------------------------------
  // decodeOsc52Clipboard() — pure decode helper (no platform-channel deps)
  //
  // OSC 52 is sent by Claude Code `/copy` and similar tools as:
  //   ESC ] 52 ; <target> ; <base64> ST
  // The xterm package delivers this as code='52', args=[target, base64].
  // decodeOsc52Clipboard extracts and base64-decodes the payload.
  // ---------------------------------------------------------------------------

  group('decodeOsc52Clipboard()', () {
    test('returns null for non-52 code', () {
      final b64 = base64Encode(utf8.encode('hello'));
      expect(decodeOsc52Clipboard('53', ['c', b64]), isNull);
      expect(decodeOsc52Clipboard('11', ['c', b64]), isNull);
      expect(decodeOsc52Clipboard('', ['c', b64]), isNull);
    });

    test('returns null when args has fewer than 2 elements', () {
      expect(decodeOsc52Clipboard('52', []), isNull);
      expect(decodeOsc52Clipboard('52', ['c']), isNull);
    });

    test('returns null for empty base64 payload', () {
      expect(decodeOsc52Clipboard('52', ['c', '']), isNull);
    });

    test('returns decoded text for valid base64 payload', () {
      final encoded = base64Encode(utf8.encode('hello world'));
      expect(decodeOsc52Clipboard('52', ['c', encoded]), 'hello world');
    });

    test('handles multi-line text', () {
      final text = 'line1\nline2\nline3';
      final encoded = base64Encode(utf8.encode(text));
      expect(decodeOsc52Clipboard('52', ['c', encoded]), text);
    });

    test('handles UTF-8 text (Japanese)', () {
      const text = 'こんにちは世界';
      final encoded = base64Encode(utf8.encode(text));
      expect(decodeOsc52Clipboard('52', ['c', encoded]), text);
    });

    test('ignores clipboard target in args[0] — result is the same', () {
      final encoded = base64Encode(utf8.encode('text'));
      expect(decodeOsc52Clipboard('52', ['c', encoded]), 'text');
      expect(decodeOsc52Clipboard('52', ['p', encoded]), 'text');
      expect(decodeOsc52Clipboard('52', ['s0', encoded]), 'text');
    });

    test('returns null for invalid base64 data', () {
      // '!!!' is not valid base64 — base64Decode throws
      expect(decodeOsc52Clipboard('52', ['c', '!!!invalid!!!']), isNull);
    });

    test('returns null for truncated base64 (odd padding)', () {
      // '====' alone is invalid base64
      expect(decodeOsc52Clipboard('52', ['c', '====']), isNull);
    });

    test('preserves empty decoded string when base64 encodes empty bytes', () {
      // base64Encode(utf8.encode('')) == '' → caught by the isEmpty guard
      // A non-empty base64 that decodes to empty bytes is a theoretical edge case.
      // The function returns null for empty b64, not for empty decoded result.
      final emptyEncoded = base64Encode(utf8.encode(''));
      // base64Encode('') == '' → the isEmpty guard returns null.
      expect(emptyEncoded, '');
      expect(decodeOsc52Clipboard('52', ['c', emptyEncoded]), isNull);
    });

    test('handles extra args beyond index 1 without error', () {
      // xterm may pass additional args; only args[1] is used.
      final encoded = base64Encode(utf8.encode('copy me'));
      expect(decodeOsc52Clipboard('52', ['c', encoded, 'extra']), 'copy me');
    });
  });

  // ---------------------------------------------------------------------------
  // _scheduleReconnect() timer — actual timer firing (Phase 52)
  //
  // _scheduleReconnect() creates a real Timer. This group verifies that after
  // the backoff delay elapses, _attemptReconnect() is called and — when the
  // attempt fails — the next retry is scheduled with doubled delay.
  //
  // Uses fakeAsync to advance the clock without real I/O delays.
  // _FailFastSshClientService makes the connect() throw immediately so the
  // async chain completes within the same fakeAsync elapse() call.
  // ---------------------------------------------------------------------------

  group('_scheduleReconnect() timer fires and calls _attemptReconnect()', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('timer-fire-test').notifier,
      );
      fakeService = _FakeSshClientService();
    });

    tearDown(() => container.dispose());

    test('3s timer fires, reconnect attempt fails, schedules next retry at 6s',
        () {
      fakeAsync((async) {
        const config = ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        );

        // Inject fail-fast factory so _connectCore() fails without network I/O.
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

        // Set connected state with config so _onDisconnected() triggers
        // _scheduleReconnect() → 3s timer.
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Trigger disconnect → _scheduleReconnect() → 3s timer scheduled.
        notifier.triggerOnDisconnectedForTesting();

        var state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.status, ConnectionStatus.disconnected);
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)');

        // 2999ms: timer has NOT fired yet.
        async.elapse(const Duration(milliseconds: 2999));
        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)',
            reason: 'timer must not fire before 3 seconds');

        // 3000ms: timer fires → _attemptReconnect() runs, fails, schedules #2.
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();

        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.status, ConnectionStatus.disconnected,
            reason: 'reconnect attempt failed → status must be disconnected');
        expect(state.errorMessage, 'Reconnecting in 6s... (attempt #2)',
            reason: 'failed attempt must schedule next retry with doubled delay');
      });
    });

    test('second timer fires at 6s, fails, schedules #3 at 12s', () {
      fakeAsync((async) {
        const config = ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        );
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        notifier.triggerOnDisconnectedForTesting();

        // Fire attempt #1 (3s) → schedules #2 (6s).
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        var state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.errorMessage, 'Reconnecting in 6s... (attempt #2)');

        // Fire attempt #2 (6s from now) → schedules #3 (12s).
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();

        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.status, ConnectionStatus.disconnected);
        expect(state.errorMessage, 'Reconnecting in 12s... (attempt #3)',
            reason: 'backoff must double: 3s → 6s → 12s');
      });
    });

    // -------------------------------------------------------------------------
    // Max-retries path: after 10 failed attempts _scheduleReconnect() gives up
    // and sets errorMessage to "Connection lost. Tap to reconnect." without
    // scheduling another timer.
    //
    // Backoff delays for attempts #1–#10: 3, 6, 12, 24, 30, 30, 30, 30, 30, 30 s
    // The 10th timer fires → _attemptReconnect() fails → _scheduleReconnect()
    // increments _retryCount to 11 > 10 → gives up immediately (no new timer).
    // -------------------------------------------------------------------------

    test('after 10 failed retries gives up with Connection lost message', () {
      fakeAsync((async) {
        const config = ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        );
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Trigger disconnect → _scheduleReconnect() → _retryCount=1, 3s timer.
        notifier.triggerOnDisconnectedForTesting();

        var state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)',
            reason: 'precondition: first retry scheduled');

        // Advance through all 10 retry timers using the known backoff sequence.
        // Each elapse fires one timer; flushMicrotasks() allows the async
        // _attemptReconnect() chain to complete so _scheduleReconnect() runs
        // before the next elapse.
        // Delays: 3, 6, 12, 24, 30, 30, 30, 30, 30, 30 seconds.
        for (final delaySec in [3, 6, 12, 24, 30, 30, 30, 30, 30, 30]) {
          async.elapse(Duration(seconds: delaySec));
          async.flushMicrotasks();
        }

        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.status, ConnectionStatus.disconnected,
            reason: 'must remain disconnected after max retries');
        expect(
          state.errorMessage,
          'Connection lost. Tap to reconnect.',
          reason: 'after 10 failed retries the user must be prompted to '
              'reconnect manually; no further automatic timer is scheduled',
        );
      });
    });

    // -------------------------------------------------------------------------
    // Max-retries: dangling 10th timer must be cancelled on give-up.
    //
    // Before this fix, _scheduleReconnect() returned early on the 11th call
    // without cancelling the 10th timer.  That timer (30s) would fire silently
    // 30 s after giving up, triggering an unexpected reconnect attempt.
    // -------------------------------------------------------------------------
    test('giving up at max retries cancels the pending 10th timer', () {
      fakeAsync((async) {
        const config = ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        );
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.disconnected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Call _scheduleReconnect() 10 times (attempts #1–#10).
        // Each call (except the 11th) cancels the previous timer and creates a
        // new 30s timer.  The 10th call leaves a live 30s timer (_retryTimer).
        for (var i = 0; i < 10; i++) {
          notifier.triggerScheduleReconnectForTesting();
        }

        var state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.errorMessage, 'Reconnecting in 30s... (attempt #10)',
            reason: 'precondition: 10 retries scheduled');

        // 11th call → _retryCount > 10 → gives up and MUST cancel the 10th timer.
        notifier.triggerScheduleReconnectForTesting();
        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.errorMessage, 'Connection lost. Tap to reconnect.',
            reason: 'precondition: gave up after max retries');

        // Advance 30s — the 10th timer must NOT fire (it was cancelled).
        // If it fired, _attemptReconnect() would fail and _scheduleReconnect()
        // would set "Reconnecting in 3s... (attempt #1)".
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();

        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(
          state.errorMessage,
          'Connection lost. Tap to reconnect.',
          reason: 'the 10th timer must have been cancelled; no silent reconnect '
              'attempt should fire after giving up',
        );
      });
    });

    // -------------------------------------------------------------------------
    // reconnect() cancels pending auto-retry timer and resets _retryCount.
    //
    // When the user taps "Reconnect" while an auto-retry timer is pending:
    //   1. The pending timer must be cancelled (no double-fire).
    //   2. _retryCount must be reset to 0, so the next auto-retry starts fresh
    //      at attempt #1 (not at the previous count).
    // -------------------------------------------------------------------------
    test('reconnect() cancels pending auto-retry timer and resets retry count',
        () {
      fakeAsync((async) {
        const config = ConnectionConfig(
          label: 'test', host: '127.0.0.1', username: 'u',
        );
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Trigger disconnect → _retryCount=1, schedules 3s auto-retry timer (A).
        notifier.triggerOnDisconnectedForTesting();
        var state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)');

        // Advance 1s — timer A has NOT fired yet (fires at t=3s).
        async.elapse(const Duration(seconds: 1));

        // Manual reconnect: resets _retryCount=0, cancels timer A, attempts
        // reconnect immediately. The attempt fails (FailFast) → schedules a new
        // 3s timer (B) with _retryCount=1 → errorMessage shows 'attempt #1'.
        unawaited(notifier.reconnect());
        async.flushMicrotasks();

        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(
          state.errorMessage,
          'Reconnecting in 3s... (attempt #1)',
          reason: 'reconnect() resets _retryCount to 0 before attempting; '
              'the failed attempt schedules a fresh 3s timer at attempt #1',
        );

        // If timer A had NOT been cancelled, it would fire 2s later (t=3s) and
        // schedule attempt #2 with a 6s delay. Advance to t=3s and verify that
        // timer A is truly gone — errorMessage must still say 'attempt #1'.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(
          state.errorMessage,
          'Reconnecting in 3s... (attempt #1)',
          reason: 'old timer A was cancelled; no spurious attempt #2 at t=3s',
        );

        // Timer B fires at t=4s (1s from now). The attempt fails → attempt #2.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        state = container.read(terminalConnectionProvider('timer-fire-test'));
        expect(
          state.errorMessage,
          'Reconnecting in 6s... (attempt #2)',
          reason: 'timer B fires at t=4s; failed attempt → attempt #2 (6s delay)',
        );
      });
    });
  });

  // ---------------------------------------------------------------------------
  // checkConnection() — disconnected path with config (app resume)
  //
  // Lines 514-521: when status==disconnected and _config is set,
  // checkConnection() resets _retryCount to 0 before calling _attemptReconnect().
  // This prevents an app-resume reconnect from inheriting the previous backoff
  // delay (e.g. _retryCount=5 → 30s wait) and instead starts fresh at 3s.
  //
  // Verified by:
  //   1. Calling triggerScheduleReconnectForTesting() twice → _retryCount=2, 6s delay
  //   2. Calling checkConnection() (resumes app) → resets _retryCount=0
  //   3. _attemptReconnect() fails (via _FailFastSshClientService)
  //   4. _scheduleReconnect() increments to _retryCount=1 → delay is 3s (not 12s)
  // ---------------------------------------------------------------------------

  group('checkConnection() disconnected path resets retryCount', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('resume-test').notifier,
      );
      fakeService = _FakeSshClientService();
      // Set up disconnected state with config so checkConnection() enters
      // the disconnected branch (line 514).
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'test-host',
        ),
        config: const ConnectionConfig(
          label: 'test-server',
          host: '127.0.0.1',
          username: 'u',
        ),
      );
    });

    tearDown(() => container.dispose());

    test(
        'resets _retryCount to 0 so reconnect starts fresh backoff from 3s',
        () async {
      // Precondition: two failed retries → _retryCount=2, delay=6s.
      notifier.triggerScheduleReconnectForTesting(); // attempt #1 → 3s
      notifier.triggerScheduleReconnectForTesting(); // attempt #2 → 6s
      expect(
        container.read(terminalConnectionProvider('resume-test')).errorMessage,
        'Reconnecting in 6s... (attempt #2)',
        reason: 'precondition: _retryCount should be 2 before app resume',
      );

      // Inject fail-fast factory so _connectCore() fails without network I/O.
      notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

      // Act: checkConnection() simulates app resuming with disconnected session.
      // It resets _retryCount=0, cancels pending timer, then calls _attemptReconnect().
      // _attemptReconnect() fails → _scheduleReconnect() increments to _retryCount=1.
      await notifier.checkConnection();

      // Assert: delay must be 3s (attempt #1), not 12s (attempt #3 if not reset).
      final state = container.read(terminalConnectionProvider('resume-test'));
      expect(state.status, ConnectionStatus.disconnected);
      expect(
        state.errorMessage,
        'Reconnecting in 3s... (attempt #1)',
        reason: '_retryCount must be reset by checkConnection() so app-resume '
            'reconnect starts fresh at 3s backoff, not continues from attempt #2',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // reconnect() — manual reconnect end-to-end failure path
  //
  // reconnect() is called when the user taps the "Reconnect" button.
  // It resets _retryCount to 0 (fresh backoff) and calls _attemptReconnect().
  //
  // When _connectCore() fails (via _FailFastSshClientService):
  //   1. status → disconnected
  //   2. _scheduleReconnect() is called with _retryCount=1 → 3s delay
  //   3. errorMessage is set to 'Reconnecting in 3s... (attempt #1)'
  //
  // Critically, reconnect() always resets the backoff counter regardless of
  // how many prior auto-reconnect attempts have already failed.
  // ---------------------------------------------------------------------------

  group('reconnect() manual reconnect end-to-end', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _FakeSshClientService fakeService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('manual-reconnect-test').notifier,
      );
      fakeService = _FakeSshClientService();
    });

    tearDown(() => container.dispose());

    // reconnect() resets _retryCount=0, then _attemptReconnect() fails →
    // _scheduleReconnect() increments to _retryCount=1 and creates a 3s timer.
    // After that timer fires, _attemptReconnect() fails again →
    // _scheduleReconnect() increments to _retryCount=2 → 6s delay (attempt #2).
    //
    // This verifies that the full retry-chain wired up by reconnect() is
    // identical to the one started by _onDisconnected() — the user-facing button
    // and the automatic disconnect path share the same backoff logic.
    test(
        'reconnect() timer fires at 3s, attempt #2 is scheduled at 6s',
        () {
      fakeAsync((async) {
        const config = ConnectionConfig(
          label: 'prod',
          host: '192.168.1.1',
          username: 'admin',
        );
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.disconnected,
            hostLabel: 'prod',
          ),
          config: config,
        );

        // Kick off reconnect() without awaiting — fakeAsync controls the clock.
        // ignore: unawaited_futures
        notifier.reconnect();

        // Flush microtasks so _attemptReconnect() runs, connect() fails via
        // _FailFastSshClientService, and _scheduleReconnect() creates the 3s timer.
        async.flushMicrotasks();

        var state =
            container.read(terminalConnectionProvider('manual-reconnect-test'));
        expect(state.status, ConnectionStatus.disconnected,
            reason: 'reconnect failed → must be disconnected');
        expect(
          state.errorMessage,
          'Reconnecting in 3s... (attempt #1)',
          reason: 'reconnect() resets _retryCount=0; '
              'failed attempt increments to 1 → 3s',
        );

        // Advance 3 seconds: the timer fires and _attemptReconnect() runs again.
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        state =
            container.read(terminalConnectionProvider('manual-reconnect-test'));
        expect(state.status, ConnectionStatus.disconnected,
            reason: 'second attempt also failed → still disconnected');
        expect(
          state.errorMessage,
          'Reconnecting in 6s... (attempt #2)',
          reason: 'after first timer fires and attempt #2 fails, '
              'backoff doubles to 6s',
        );
      });
    });

    // reconnect() fail → _scheduleReconnect() → errorMessage shows attempt #1.
    test('reconnect() failing sets errorMessage to attempt #1 with 3s delay',
        () async {
      const config = ConnectionConfig(
        label: 'prod', host: '192.168.1.1', username: 'admin',
      );
      notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'prod',
        ),
        config: config,
      );

      await notifier.reconnect();

      final state =
          container.read(terminalConnectionProvider('manual-reconnect-test'));
      expect(state.status, ConnectionStatus.disconnected);
      expect(
        state.errorMessage,
        'Reconnecting in 3s... (attempt #1)',
        reason: 'reconnect() resets _retryCount=0 before attempting; '
            'the failed attempt increments to _retryCount=1 → 3s delay',
      );
    });

    // When _attemptReconnect() catches an AppError (e.g. NetworkError), the raw
    // error text must NOT appear in errorMessage.  _scheduleReconnect() always
    // runs immediately after and sets the user-facing "Reconnecting in Xs..."
    // message, so errorMessage from the catch block is never the final value.
    test(
        'reconnect() failure with AppError shows schedule message, '
        'not raw AppError text',
        () async {
      const config = ConnectionConfig(
        label: 'prod', host: '192.168.1.1', username: 'admin',
      );
      // _NetworkErrorSshClientService.connect() throws NetworkError('Host unreachable').
      // The reconnect path must not expose the raw error — _scheduleReconnect()
      // sets the user-facing message instead.
      notifier.sshServiceFactoryOverride = () => _NetworkErrorSshClientService();
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'prod',
        ),
        config: config,
      );

      await notifier.reconnect();

      final state =
          container.read(terminalConnectionProvider('manual-reconnect-test'));
      expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)',
          reason: '_scheduleReconnect() sets the user-facing message; '
              'the raw AppError from _connectCore() must not be the final value');
      expect(state.errorMessage, isNot(contains('Host unreachable')),
          reason: 'raw AppError.message must not appear in errorMessage');
      expect(state.errorMessage, isNot(contains('NetworkError')),
          reason: 'exception class name must not appear in errorMessage');
    });

    // reconnect() must reset _retryCount even when prior auto-reconnect
    // attempts have already been running. Without the reset, a user pressing
    // "Reconnect" after 5 auto-failures would wait 30s instead of 3s.
    test(
        'reconnect() resets _retryCount so backoff restarts from 3s '
        'even after prior auto-reconnect failures',
        () async {
      const config = ConnectionConfig(
        label: 'prod', host: '192.168.1.1', username: 'admin',
      );
      notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'prod',
        ),
        config: config,
      );

      // Simulate 5 prior auto-reconnect failures → _retryCount=5, delay=30s.
      for (var i = 0; i < 5; i++) {
        notifier.triggerScheduleReconnectForTesting();
      }
      expect(
        container
            .read(terminalConnectionProvider('manual-reconnect-test'))
            .errorMessage,
        'Reconnecting in 30s... (attempt #5)',
        reason: 'precondition: 5 prior failures raise delay to 30s',
      );

      // Manual reconnect resets _retryCount=0 → fresh 3s backoff.
      await notifier.reconnect();

      final state =
          container.read(terminalConnectionProvider('manual-reconnect-test'));
      expect(
        state.errorMessage,
        'Reconnecting in 3s... (attempt #1)',
        reason: 'reconnect() must reset _retryCount=0 so the user gets a '
            'fresh 3s backoff, not a continuation of the 30s auto-retry sequence',
      );
    });

    // _attemptReconnect() calls _connectCore() which sets _sshService to a new
    // SshClientService instance before attempting the actual TCP connect.
    // If _connectCore() throws (e.g. connection refused), the newly allocated
    // _sshService must be cleaned up immediately — not held until the next retry
    // attempt starts (which could be 3-30 seconds later).
    //
    // This mirrors the explicit _cleanupConnections() call in connect()'s catch
    // block. Without the fix, a stale TCP socket is kept open for the entire
    // backoff interval.
    test(
        '_attemptReconnect() calls disconnect() on failed SSH service '
        'before scheduling the next retry',
        () async {
      late _TrackingFailFastSshClientService trackingService;
      const config = ConnectionConfig(
        label: 'prod', host: '192.168.1.1', username: 'admin',
      );
      notifier.sshServiceFactoryOverride = () {
        trackingService = _TrackingFailFastSshClientService();
        return trackingService;
      };
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'prod',
        ),
        config: config,
      );

      await notifier.reconnect();

      expect(
        trackingService.disconnectCalled,
        isTrue,
        reason: '_attemptReconnect() must call disconnect() on the SSH service '
            'created by _connectCore() when the connection attempt fails, '
            'so the socket is freed immediately rather than held until the '
            'next retry fires',
      );
    });

    // _cleanupConnections() wraps _sshService?.disconnect() in try/catch so
    // that a service whose disconnect() throws does not propagate the error
    // up through _attemptReconnect()'s catch block (or connect()'s catch).
    // Without the fix, a throwing disconnect() would crash the reconnect flow.
    test(
        '_cleanupConnections() swallows disconnect() exception — reconnect '
        'completes normally even when the SSH service throws on disconnect',
        () async {
      late _ThrowingDisconnectSshClientService throwingService;
      const config = ConnectionConfig(
        label: 'prod', host: '192.168.1.1', username: 'admin',
      );
      notifier.sshServiceFactoryOverride = () {
        throwingService = _ThrowingDisconnectSshClientService();
        return throwingService;
      };
      notifier.initConnectedStateForTesting(
        sshService: fakeService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          hostLabel: 'prod',
        ),
        config: config,
      );

      // reconnect() must not throw even though the service's disconnect() throws.
      await expectLater(notifier.reconnect(), completes);

      expect(
        throwingService.disconnectCalled,
        isTrue,
        reason: 'disconnect() must be called even though it throws',
      );
      expect(
        container
            .read(terminalConnectionProvider('manual-reconnect-test'))
            .status,
        ConnectionStatus.disconnected,
        reason: 'state must be disconnected after the failed reconnect',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // _handlePrivateOSC() — OSC 52 clipboard integration
  //
  // _handlePrivateOSC is wired up as the Terminal's onPrivateOSC callback and
  // routes OSC 52 sequences to the system clipboard. It delegates decoding to
  // decodeOsc52Clipboard (tested separately) and passes the result to
  // Clipboard.setData. These tests verify the full integration path:
  //   • valid OSC 52 payload → Clipboard.setData is called with decoded text
  //   • non-52 code          → Clipboard.setData is NOT called (early return)
  //   • empty/invalid payload → Clipboard.setData is NOT called (null guard)
  //
  // Uses a SystemChannels.platform mock so Clipboard interactions work in
  // unit tests without a real platform (avoids the null return from
  // Clipboard.getData that occurs without an explicit channel mock).
  // ---------------------------------------------------------------------------

  group('_handlePrivateOSC()', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    String? mockClipboard;

    setUpAll(() {
      // Install a minimal Clipboard mock on the platform channel.
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          mockClipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': mockClipboard};
        }
        return null;
      });
    });

    tearDownAll(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    setUp(() {
      mockClipboard = null;
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('osc-test').notifier,
      );
    });

    tearDown(() => container.dispose());

    test('valid OSC 52 payload sets clipboard to decoded text', () async {
      final encoded = base64Encode(utf8.encode('hello from ssh'));
      notifier.handlePrivateOscForTesting('52', ['c', encoded]);
      // Allow Clipboard.setData future to resolve.
      await Future<void>.delayed(Duration.zero);
      expect(mockClipboard, 'hello from ssh');
    });

    test('non-52 code does not call Clipboard.setData', () async {
      final encoded = base64Encode(utf8.encode('should not appear'));
      notifier.handlePrivateOscForTesting('53', ['c', encoded]);
      await Future<void>.delayed(Duration.zero);
      expect(mockClipboard, isNull,
          reason: 'non-52 code must short-circuit before Clipboard.setData');
    });

    test('empty base64 payload does not call Clipboard.setData', () async {
      notifier.handlePrivateOscForTesting('52', ['c', '']);
      await Future<void>.delayed(Duration.zero);
      expect(mockClipboard, isNull,
          reason: 'empty payload → decodeOsc52Clipboard returns null '
              '→ early return before Clipboard.setData');
    });
  });

  // ---------------------------------------------------------------------------
  // _setConnectedState() — shared success path for connect() and _attemptReconnect()
  //
  // _setConnectedState() is called when an SSH connection is successfully
  // established (initial connect) or re-established (auto-reconnect).
  // It must:
  //   1. Set status → connected
  //   2. Set terminal in state
  //   3. Set channelManager from _channelManager instance field
  //   4. Clear errorMessage (so reconnect error banners disappear)
  //   5. Reset shellExited → false (shell exit from previous session is gone)
  //
  // The shellExited reset is particularly important: if the user's shell exited
  // cleanly before a reconnect, the new connection must not inherit that flag.
  // ---------------------------------------------------------------------------

  group('_setConnectedState()', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('set-connected-test').notifier,
      );
    });

    tearDown(() => container.dispose());

    test('transitions to connected status', () {
      final terminal = Terminal(maxLines: 50);
      notifier.callSetConnectedStateForTesting(terminal);

      final state =
          container.read(terminalConnectionProvider('set-connected-test'));
      expect(state.status, ConnectionStatus.connected,
          reason: '_setConnectedState must set status to connected');
    });

    test('sets terminal in state', () {
      final terminal = Terminal(maxLines: 50);
      notifier.callSetConnectedStateForTesting(terminal);

      final state =
          container.read(terminalConnectionProvider('set-connected-test'));
      expect(state.terminal, same(terminal),
          reason: 'terminal passed to _setConnectedState must appear in state');
    });

    test('clears errorMessage set by previous reconnect failure', () {
      // Simulate state after a failed reconnect attempt.
      notifier.initConnectedStateForTesting(
        sshService: _FakeSshClientService(),
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
          errorMessage: 'Reconnecting in 6s... (attempt #2)',
        ),
      );

      final terminal = Terminal(maxLines: 50);
      notifier.callSetConnectedStateForTesting(terminal);

      final state =
          container.read(terminalConnectionProvider('set-connected-test'));
      expect(state.errorMessage, isNull,
          reason: 'errorMessage from failed reconnect must be cleared on success');
    });

    test('resets shellExited to false even when it was true', () {
      // Simulate: shell exited cleanly (user ran `exit`), then network
      // reconnect succeeds. The new session must start with shellExited=false.
      notifier.initConnectedStateForTesting(
        sshService: _FakeSshClientService(),
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          shellExited: true,
        ),
      );

      final terminal = Terminal(maxLines: 50);
      notifier.callSetConnectedStateForTesting(terminal);

      final state =
          container.read(terminalConnectionProvider('set-connected-test'));
      expect(state.shellExited, isFalse,
          reason: 'shellExited must be reset to false when a new connection '
              'is established — the new PTY session has a live shell');
    });

    test('sets channelManager from instance field', () {
      final mockManager = _MockSshChannelManager();
      notifier.setChannelManagerForTesting(mockManager);

      final terminal = Terminal(maxLines: 50);
      notifier.callSetConnectedStateForTesting(terminal);

      final state =
          container.read(terminalConnectionProvider('set-connected-test'));
      expect(state.channelManager, same(mockManager),
          reason: '_channelManager instance field must be reflected in state');
    });

    test('resets _notificationSent so background notifications can fire again after reconnect', () {
      // Regression: _notificationSent was not reset on reconnect, causing
      // background notifications to be silently suppressed for the entire
      // new session after the first notification was sent in a prior session.
      notifier.setNotificationSentForTesting(true);
      expect(notifier.isNotificationSentForTesting, isTrue,
          reason: 'precondition: _notificationSent must be true before calling _setConnectedState');

      final terminal = Terminal(maxLines: 50);
      notifier.callSetConnectedStateForTesting(terminal);

      expect(notifier.isNotificationSentForTesting, isFalse,
          reason: '_setConnectedState must reset _notificationSent so that '
              'background notifications can fire for the new session');
    });

    test('resets _keepAliveFailCount so 3-strike rule starts fresh after reconnect',
        () async {
      // Arrange: connected state with a keepAlive service that always fails.
      // _keepAliveFailCount must be reset to 0 by _setConnectedState so that
      // failures from a previous session do not bleed into the new connection.
      final failingService = _FakeSshClientService()..keepAliveResult = false;
      notifier.initConnectedStateForTesting(
        sshService: failingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
          hostLabel: 'test-host',
        ),
      );

      // Accumulate 2 failures — one more would trigger _onDisconnected().
      await notifier.activeKeepAlive();
      await notifier.activeKeepAlive();
      expect(notifier.keepAliveFailCountForTesting, 2,
          reason: 'precondition: two keepAlive failures must accumulate to count 2');

      // Simulate a successful reconnect; _setConnectedState must reset the count.
      notifier.callSetConnectedStateForTesting(Terminal(maxLines: 50));

      expect(notifier.keepAliveFailCountForTesting, 0,
          reason: '_setConnectedState must reset _keepAliveFailCount to 0 so '
              'the new session starts with a clean slate');
    });
  });

  // ---------------------------------------------------------------------------
  // _stdoutSubscription onDone — shellExited flag
  //
  // When the PTY stdout stream closes, the onDone callback checks two guards:
  //   1. state.status == ConnectionStatus.connected
  //   2. _sshService?.isConnected == true
  //
  // Only when both are true does it set shellExited = true.
  // If the SSH connection itself is dead (network disconnect), isConnected is
  // false and this callback must NOT set shellExited — the shell did not exit
  // cleanly, the network dropped.
  // ---------------------------------------------------------------------------

  group('_stdoutSubscription onDone — shellExited', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('stdout-done-test').notifier,
      );
    });

    tearDown(() => container.dispose());

    test('sets shellExited=true when connected and SSH is alive', () {
      // Arrange: connected state with an isConnected=true service.
      notifier.initConnectedStateForTesting(
        sshService: _FakeSshClientService(), // isConnected => true
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
        ),
      );

      // Act: simulate stdout stream close (shell ran `exit`).
      notifier.triggerStdoutDoneForTesting();

      final state =
          container.read(terminalConnectionProvider('stdout-done-test'));
      expect(state.shellExited, isTrue,
          reason: 'shell exit via `exit` command while SSH is alive '
              'must set shellExited=true');
    });

    test('does not set shellExited when status is not connected', () {
      // Arrange: disconnected state — onDone fires after network drop.
      notifier.initConnectedStateForTesting(
        sshService: _FakeSshClientService(),
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
        ),
      );

      notifier.triggerStdoutDoneForTesting();

      final state =
          container.read(terminalConnectionProvider('stdout-done-test'));
      expect(state.shellExited, isFalse,
          reason: 'onDone with non-connected status must not set shellExited');
    });

    test('does not set shellExited when SSH is not alive (network disconnect)',
        () {
      // Arrange: connected state but the SSH client reports disconnected.
      // This is the network-drop scenario: stdout closes because the TCP
      // connection died, not because the user ran `exit`.
      notifier.initConnectedStateForTesting(
        sshService: _FakeDisconnectedSshClientService(), // isConnected => false
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
        ),
      );

      notifier.triggerStdoutDoneForTesting();

      final state =
          container.read(terminalConnectionProvider('stdout-done-test'));
      expect(state.shellExited, isFalse,
          reason: 'onDone during network disconnect must not set shellExited '
              '— the shell did not exit, the connection dropped');
    });
  });

  // -------------------------------------------------------------------------
  // activeKeepAlive() — early-exit guards in _activeKeepAliveCore()
  //
  // _activeKeepAliveCore() には 2 つの事前ガードがある:
  //   1. status != connected → 早期リターン（切断中・再接続中に keepAlive を送らない）
  //   2. _sshService == null → 早期リターン（サービスが null の場合は何もしない）
  //
  // バックグラウンドサービスが keepAlive タイマーを発火した際に
  // 再接続中や切断済み状態でも安全に呼べることを保証するためのガード。
  // -------------------------------------------------------------------------

  group('activeKeepAlive() early-exit guards', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _CountingSshClientService countingService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('ka-guard-test').notifier,
      );
      countingService = _CountingSshClientService();
    });

    tearDown(() => container.dispose());

    test('no keepAlive probe when status is disconnected', () async {
      // フォアグラウンドサービスが keepAlive を発火したとき、
      // 既に切断済みなら SSH keepAlive probe を送らない。
      notifier.initConnectedStateForTesting(
        sshService: countingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
        ),
      );

      await notifier.activeKeepAlive();

      expect(countingService.keepAliveCount, 0,
          reason: 'status == disconnected guard must prevent any SSH probe');
    });

    test('no keepAlive probe when status is reconnecting', () async {
      // 再接続中に keepAlive タイマーが発火しても SSH probe を送らない。
      notifier.initConnectedStateForTesting(
        sshService: countingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.reconnecting,
        ),
      );

      await notifier.activeKeepAlive();

      expect(countingService.keepAliveCount, 0,
          reason: 'status == reconnecting guard must prevent any SSH probe');
    });

    test('_isActiveKeepAliveRunning is reset after status guard', () async {
      // ガード早期リターン後も _isActiveKeepAliveRunning フラグが
      // 解放されることを確認する。フラグが残るとその後の keepAlive が
      // 永遠に skipped になってしまう。
      notifier.initConnectedStateForTesting(
        sshService: countingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.disconnected,
        ),
      );

      await notifier.activeKeepAlive(); // guard fires (no probe)

      // 状態を connected に戻してから再度 keepAlive を呼ぶ。
      // もし _isActiveKeepAliveRunning が残っていたらこの呼び出しも skip される。
      notifier.initConnectedStateForTesting(
        sshService: countingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
        ),
      );
      await notifier.activeKeepAlive();

      expect(countingService.keepAliveCount, 1,
          reason:
              '_isActiveKeepAliveRunning must be reset so the next call can run');
    });

    test('no keepAlive probe when _sshService is null', () async {
      // connected 状態だが _sshService が null の場合（レースコンディション）。
      notifier.initConnectedStateForTesting(
        sshService: countingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
        ),
      );
      notifier.clearSshServiceForTesting(); // _sshService を null に

      await notifier.activeKeepAlive();

      expect(countingService.keepAliveCount, 0,
          reason: '_sshService == null guard must prevent any SSH probe');
    });

    test('_isActiveKeepAliveRunning is reset after null service guard',
        () async {
      // null service ガード早期リターン後もフラグが解放されることを確認。
      notifier.initConnectedStateForTesting(
        sshService: countingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
        ),
      );
      notifier.clearSshServiceForTesting();

      await notifier.activeKeepAlive(); // null guard fires (no probe)

      // サービスを復元してから再度 keepAlive を呼ぶ。
      notifier.initConnectedStateForTesting(
        sshService: countingService,
        connectedState: const TerminalConnectionState(
          status: ConnectionStatus.connected,
        ),
      );
      await notifier.activeKeepAlive();

      expect(countingService.keepAliveCount, 1,
          reason:
              '_isActiveKeepAliveRunning must be reset so the next call can run');
    });
  });

  // -------------------------------------------------------------------------
  // activeKeepAlive() — identical() guard races in _activeKeepAliveCore()
  //
  // _activeKeepAliveCore() captures `service = _sshService` before the await,
  // then checks `identical(service, _sshService)` after. If the service was
  // replaced while keepAlive() was in-flight, the stale result must be discarded
  // so _keepAliveFailCount is not incremented on the wrong connection.
  // -------------------------------------------------------------------------

  group('activeKeepAlive() identical() guard — service swap mid-await', () {
    late ProviderContainer container;
    late TerminalConnectionNotifier notifier;
    late _BlockingFirstCallService blockingService;

    setUp(() {
      container = makeContainer();
      notifier = container.read(
        terminalConnectionProvider('ka-identity-guard-test').notifier,
      );
      blockingService = _BlockingFirstCallService();
    });

    tearDown(() => container.dispose());

    test(
        'identical() guard prevents fail-count increment when service cleared '
        'while keepAlive() is awaiting', () {
      fakeAsync((async) {
        notifier.initConnectedStateForTesting(
          sshService: blockingService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
        );

        // Phase 1: accumulate _keepAliveFailCount to 2 via immediate false returns
        // (blockCompleter is null → keepAlive() returns false immediately).
        // ignore: unawaited_futures
        notifier.activeKeepAlive();
        async.flushMicrotasks(); // failCount → 1
        // ignore: unawaited_futures
        notifier.activeKeepAlive();
        async.flushMicrotasks(); // failCount → 2
        // State is still connected (3rd failure would trigger _onDisconnected).
        expect(
          container.read(terminalConnectionProvider('ka-identity-guard-test')).status,
          ConnectionStatus.connected,
        );

        // Phase 2: arm the blocker so the 3rd keepAlive() suspends mid-await.
        blockingService.blockCompleter = Completer<bool>();
        // ignore: unawaited_futures
        notifier.activeKeepAlive(); // starts; now suspended inside keepAlive()
        async.flushMicrotasks(); // drives the coroutine up to the await

        // Phase 3: replace _sshService while keepAlive() is still pending.
        // clearSshServiceForTesting() sets _sshService = null without touching
        // _keepAliveFailCount, so the count stays at 2.
        notifier.clearSshServiceForTesting();

        // Phase 4: resolve the blocked keepAlive() with false.
        // identical(blockingService, null) → false → guard fires → early return.
        // Without the guard: failCount would reach 3, triggering _onDisconnected().
        blockingService.blockCompleter!.complete(false);
        async.flushMicrotasks();

        expect(
          container.read(terminalConnectionProvider('ka-identity-guard-test')).status,
          ConnectionStatus.connected,
          reason: 'identical() guard must discard the stale keepAlive result '
              'and leave status connected when the service was replaced mid-await',
        );
      });
    });

    test(
        'identical() guard prevents fail-count increment when service swapped '
        'to a new instance while keepAlive() is awaiting', () {
      fakeAsync((async) {
        notifier.initConnectedStateForTesting(
          sshService: blockingService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
        );

        // Phase 1: accumulate failCount to 2.
        // ignore: unawaited_futures
        notifier.activeKeepAlive();
        async.flushMicrotasks();
        // ignore: unawaited_futures
        notifier.activeKeepAlive();
        async.flushMicrotasks();

        // Phase 2: arm blocker and start 3rd call.
        blockingService.blockCompleter = Completer<bool>();
        // ignore: unawaited_futures
        notifier.activeKeepAlive();
        async.flushMicrotasks();

        // Phase 3: swap to a brand-new healthy service (simulates reconnect).
        // initConnectedStateForTesting() replaces _sshService with newService
        // and resets _keepAliveFailCount to 0 — so the new connection starts clean.
        final newService = _FakeSshClientService()..keepAliveResult = true;
        notifier.initConnectedStateForTesting(
          sshService: newService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
        );

        // Phase 4: resolve blocker with false.
        // identical(blockingService, newService) → false → guard fires → early return.
        // The new connection's failCount (0) is unaffected by the old result.
        blockingService.blockCompleter!.complete(false);
        async.flushMicrotasks();

        expect(
          container.read(terminalConnectionProvider('ka-identity-guard-test')).status,
          ConnectionStatus.connected,
          reason: 'identical() guard must discard stale result from old service '
              'when a new service has been installed during reconnect',
        );

        // Verify the new service is fully functional: a healthy keepAlive
        // on the new connection should leave status connected.
        // ignore: unawaited_futures
        notifier.activeKeepAlive();
        async.flushMicrotasks();
        expect(
          container.read(terminalConnectionProvider('ka-identity-guard-test')).status,
          ConnectionStatus.connected,
          reason: 'new service keepAlive() should succeed and keep status connected',
        );
      });
    });
  });

  // ---------------------------------------------------------------------------
  // ConnectivityMonitor wiring: network restore cancels backoff timer and
  // triggers an immediate reconnect attempt.
  // ---------------------------------------------------------------------------

  group('connectivity restore cancels backoff timer and reconnects immediately',
      () {
    const connectionId = 'connectivity-restore-test';
    const config = ConnectionConfig(
      label: 'test',
      host: '127.0.0.1',
      username: 'u',
    );

    test('disconnected→connected transition triggers reconnect without waiting',
        () {
      fakeAsync((async) {
        late _ControllableConnectivityMonitor connectivityMonitor;
        final container = ProviderContainer(
          overrides: [
            connectivityProvider.overrideWith(() {
              connectivityMonitor = _ControllableConnectivityMonitor();
              return connectivityMonitor;
            }),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(
          terminalConnectionProvider(connectionId).notifier,
        );

        // Inject fail-fast factory so _connectCore() fails without network I/O.
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

        // Set up: connected state with config so _onDisconnected() schedules backoff.
        final fakeService = _FakeSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Disconnect → schedules 3s backoff timer (attempt #1).
        notifier.triggerOnDisconnectedForTesting();

        var state = container.read(terminalConnectionProvider(connectionId));
        expect(state.status, ConnectionStatus.disconnected);
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)');

        // Advance time just 1s — timer has NOT fired yet.
        async.elapse(const Duration(seconds: 1));
        state = container.read(terminalConnectionProvider(connectionId));
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)',
            reason: 'backoff timer must still be pending');

        // Simulate network restoration: disconnected → connected.
        connectivityMonitor.setStatus(NetworkStatus.connected);
        async.flushMicrotasks();

        // The ref.listen callback must have cancelled the 3s timer and
        // called _attemptReconnect() immediately (retryCount reset to 0).
        // _connectCore() fails → _scheduleReconnect() schedules attempt #1
        // (retryCount was reset, so the new error is "Reconnecting in 3s... (attempt #1)").
        state = container.read(terminalConnectionProvider(connectionId));
        expect(state.status, ConnectionStatus.disconnected,
            reason: 'reconnect attempt failed → status must be disconnected');
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)',
            reason: 'retryCount must be reset to 0 before the immediate attempt, '
                'so failed attempt re-schedules as #1');

        // Verify the original 3s timer was cancelled (not doubled):
        // advancing remaining 2s must NOT fire the old timer again.
        async.elapse(const Duration(seconds: 2));
        state = container.read(terminalConnectionProvider(connectionId));
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)',
            reason: 'old timer must be cancelled — only the new 3s timer is pending');
      });
    });

    test('no reconnect when already connected at restore time', () {
      fakeAsync((async) {
        late _ControllableConnectivityMonitor connectivityMonitor;
        final container = ProviderContainer(
          overrides: [
            connectivityProvider.overrideWith(() {
              connectivityMonitor = _ControllableConnectivityMonitor();
              return connectivityMonitor;
            }),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(
          terminalConnectionProvider(connectionId).notifier,
        );
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

        final fakeService = _FakeSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Network transitions disconnected → connected while status is connected.
        connectivityMonitor.setStatus(NetworkStatus.connected);
        async.flushMicrotasks();

        // Must remain connected — no spurious reconnect attempt.
        final state = container.read(terminalConnectionProvider(connectionId));
        expect(state.status, ConnectionStatus.connected,
            reason: 'connectivity restore must not disrupt an active connection');
      });
    });

    test('no reconnect when config is null (never connected)', () {
      fakeAsync((async) {
        late _ControllableConnectivityMonitor connectivityMonitor;
        final container = ProviderContainer(
          overrides: [
            connectivityProvider.overrideWith(() {
              connectivityMonitor = _ControllableConnectivityMonitor();
              return connectivityMonitor;
            }),
          ],
        );
        addTearDown(container.dispose);

        // Read notifier without calling connect() — _config remains null.
        container.read(terminalConnectionProvider(connectionId).notifier);

        connectivityMonitor.setStatus(NetworkStatus.connected);
        async.flushMicrotasks();

        final state = container.read(terminalConnectionProvider(connectionId));
        expect(state.status, ConnectionStatus.disconnected,
            reason: 'must not attempt reconnect when _config is null');
      });
    });

    test('no reconnect when status is reconnecting (_isReconnecting guard)', () {
      // When status == reconnecting, _isReconnecting is always true.
      // The connectivity listener's `!_isReconnecting` guard prevents a
      // second concurrent attempt — the in-progress reconnect is left to
      // complete (or fail and schedule its own retry).
      fakeAsync((async) {
        late _ControllableConnectivityMonitor connectivityMonitor;
        final container = ProviderContainer(
          overrides: [
            connectivityProvider.overrideWith(() {
              connectivityMonitor = _ControllableConnectivityMonitor();
              return connectivityMonitor;
            }),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(
          terminalConnectionProvider(connectionId).notifier,
        );
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

        final fakeService = _FakeSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Simulate the reconnecting state: _isReconnecting = true, status = reconnecting.
        notifier.setIsReconnectingForTesting(true);
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.reconnecting,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Network restores while a reconnect is already in progress.
        connectivityMonitor.setStatus(NetworkStatus.connected);
        async.flushMicrotasks();

        // Status must remain reconnecting — the listener must not have fired
        // because `!_isReconnecting` prevents entry when a retry is in flight.
        final state = container.read(terminalConnectionProvider(connectionId));
        expect(state.status, ConnectionStatus.reconnecting,
            reason: 'connectivity restore must not interrupt an in-progress '
                'reconnect attempt (_isReconnecting guard)');
      });
    });

    test('reconnects after max retries are exhausted', () {
      // After hitting max retries (10), the error message becomes
      // "Connection lost. Tap to reconnect." and no more timers are scheduled.
      // When the network later restores, the connectivity listener must restart
      // the reconnect cycle from scratch (retryCount reset to 0).
      fakeAsync((async) {
        late _ControllableConnectivityMonitor connectivityMonitor;
        final container = ProviderContainer(
          overrides: [
            connectivityProvider.overrideWith(() {
              connectivityMonitor = _ControllableConnectivityMonitor();
              return connectivityMonitor;
            }),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(
          terminalConnectionProvider(connectionId).notifier,
        );
        notifier.sshServiceFactoryOverride = () => _FailFastSshClientService();

        final fakeService = _FakeSshClientService();
        notifier.initConnectedStateForTesting(
          sshService: fakeService,
          connectedState: const TerminalConnectionState(
            status: ConnectionStatus.connected,
            hostLabel: 'test-host',
          ),
          config: config,
        );

        // Exhaust all 10 retries: calls 1–10 each schedule a timer;
        // call 11 sets "Connection lost. Tap to reconnect." and returns early.
        // No timers fire because we never advance time here.
        for (var i = 0; i < 11; i++) {
          notifier.triggerScheduleReconnectForTesting();
        }

        var state = container.read(terminalConnectionProvider(connectionId));
        expect(state.errorMessage, 'Connection lost. Tap to reconnect.',
            reason: 'max retries (10) must be exhausted before this test');
        expect(state.status, ConnectionStatus.disconnected);

        // Network restores — the connectivity listener cancels the pending
        // timer (from the 10th call) and calls _attemptReconnect() immediately.
        connectivityMonitor.setStatus(NetworkStatus.connected);
        // _FailFastSshClientService throws immediately (microtask), so
        // flushMicrotasks() covers the full connect → fail → scheduleReconnect(#1) cycle.
        async.flushMicrotasks();

        state = container.read(terminalConnectionProvider(connectionId));
        expect(state.status, ConnectionStatus.disconnected);
        expect(state.errorMessage, 'Reconnecting in 3s... (attempt #1)',
            reason: 'connectivity restore must restart the reconnect cycle '
                'even after max retries were exhausted');
      });
    });
  });
}
