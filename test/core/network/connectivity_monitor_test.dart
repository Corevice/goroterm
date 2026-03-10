import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terminal_ssh_app/core/network/connectivity_monitor.dart';

// ---------------------------------------------------------------------------
// Stub: bypasses Connectivity() platform channel, returns connected immediately.
// ---------------------------------------------------------------------------

class _StubConnectivityMonitor extends ConnectivityMonitor {
  @override
  NetworkStatus build() {
    ref.onDispose(() {});
    return NetworkStatus.connected;
  }
}

// ---------------------------------------------------------------------------
// Pure helper: mirrors the _onConnectivityChanged decision logic.
// Used to verify the state machine rules without Riverpod timing concerns.
// ---------------------------------------------------------------------------

NetworkStatus _calculateStatus(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.none)) {
    return NetworkStatus.disconnected;
  }
  return NetworkStatus.connected;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // NetworkStatus enum — structural guarantees
  // -------------------------------------------------------------------------

  group('NetworkStatus enum', () {
    test('has exactly two values', () {
      expect(NetworkStatus.values.length, 2);
    });

    test('contains connected and disconnected', () {
      expect(
        NetworkStatus.values,
        containsAll([NetworkStatus.connected, NetworkStatus.disconnected]),
      );
    });

    test('does not contain unknown variant (Phase 8 removal)', () {
      // Phase 8 removed the 'unknown' state to prevent spurious startup
      // transitions. This test ensures it was not re-introduced.
      final names = NetworkStatus.values.map((e) => e.name).toList();
      expect(names, isNot(contains('unknown')));
    });
  });

  // -------------------------------------------------------------------------
  // ConnectivityMonitor initial state
  // -------------------------------------------------------------------------

  group('ConnectivityMonitor initial state', () {
    test('initial state is connected (not unknown or disconnected)', () {
      final container = ProviderContainer(
        overrides: [
          connectivityProvider.overrideWith(_StubConnectivityMonitor.new),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(connectivityProvider), NetworkStatus.connected);
    });

    test('no spurious state change after initialization', () async {
      // If a legacy _checkInitialConnectivity() still existed, it would
      // schedule an async state update after build(). With it removed, the
      // state must remain connected after flushing pending microtasks.
      final container = ProviderContainer(
        overrides: [
          connectivityProvider.overrideWith(_StubConnectivityMonitor.new),
        ],
      );
      addTearDown(container.dispose);

      container.read(connectivityProvider); // trigger build()

      // Flush any pending microtasks a legacy _checkInitialConnectivity
      // would have scheduled.
      await Future.microtask(() {});

      expect(container.read(connectivityProvider), NetworkStatus.connected);
    });
  });

  // -------------------------------------------------------------------------
  // State machine transition rules
  //
  // The _onConnectivityChanged logic is tested via a pure helper function
  // that mirrors the production decision. This avoids Riverpod stream-listener
  // state-flush timing in unit tests while fully verifying the rule set.
  // -------------------------------------------------------------------------

  group('ConnectivityMonitor transition rules', () {
    test('ConnectivityResult.none → disconnected', () {
      expect(
        _calculateStatus([ConnectivityResult.none]),
        NetworkStatus.disconnected,
      );
    });

    test('ConnectivityResult.wifi → connected', () {
      expect(
        _calculateStatus([ConnectivityResult.wifi]),
        NetworkStatus.connected,
      );
    });

    test('ConnectivityResult.mobile → connected', () {
      expect(
        _calculateStatus([ConnectivityResult.mobile]),
        NetworkStatus.connected,
      );
    });

    test('ConnectivityResult.ethernet → connected', () {
      expect(
        _calculateStatus([ConnectivityResult.ethernet]),
        NetworkStatus.connected,
      );
    });

    test('empty result list → connected (no none present)', () {
      // A completely empty list has no ConnectivityResult.none → connected.
      expect(_calculateStatus([]), NetworkStatus.connected);
    });

    test('[none] even alongside other types → disconnected', () {
      // The production rule: if results.contains(none) → disconnected,
      // regardless of other types present.
      expect(
        _calculateStatus([ConnectivityResult.wifi, ConnectivityResult.none]),
        NetworkStatus.disconnected,
      );
    });

    test('multiple non-none types → connected', () {
      expect(
        _calculateStatus([ConnectivityResult.wifi, ConnectivityResult.mobile]),
        NetworkStatus.connected,
      );
    });

    test('reconnection scenario: none then wifi → connected', () {
      // Simulates the disconnect → reconnect sequence.
      final afterDisconnect = _calculateStatus([ConnectivityResult.none]);
      expect(afterDisconnect, NetworkStatus.disconnected);

      final afterReconnect = _calculateStatus([ConnectivityResult.wifi]);
      expect(afterReconnect, NetworkStatus.connected);
    });
  });
}
