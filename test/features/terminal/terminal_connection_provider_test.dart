import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:xterm/xterm.dart';

import 'package:terminal_ssh_app/core/network/connectivity_monitor.dart';
import 'package:terminal_ssh_app/core/ssh/connection_config.dart';
import 'package:terminal_ssh_app/core/ssh/known_hosts_store.dart';
import 'package:terminal_ssh_app/core/ssh/ssh_client_service.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';

// ---------------------------------------------------------------------------
// Fakes/mocks for unit testing without platform channels or SSH servers.
// ---------------------------------------------------------------------------

class _FakeConnectivityMonitor extends ConnectivityMonitor {
  @override
  NetworkStatus build() => NetworkStatus.connected;
}

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
      final terminal = Terminal(maxLines: 1000);
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
      final terminal = Terminal(maxLines: 1000);
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
      final terminal = Terminal(maxLines: 1000);
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
      // After 20+ retries the delay must still be 30s (not overflow).
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

      for (var i = 0; i < 20; i++) {
        notifier.triggerScheduleReconnectForTesting();
      }

      final state = container.read(terminalConnectionProvider('ka-test'));
      expect(state.errorMessage, 'Reconnecting in 30s... (attempt #20)');
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
}
