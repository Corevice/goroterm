import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum NetworkStatus {
  connected,
  disconnected,
}

class ConnectivityMonitor extends Notifier<NetworkStatus> {
  StreamSubscription? _subscription;

  @override
  NetworkStatus build() {
    _subscription?.cancel();
    _subscription = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged);
    ref.onDispose(() => _subscription?.cancel());
    // 初期状態は connected — 起動直後の spurious 遷移を防ぐ。
    // ネットワーク接続はほぼ常に利用可能で、offline の場合は
    // 最初の onConnectivityChanged で disconnected に遷移する。
    return NetworkStatus.connected;
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.none)) {
      state = NetworkStatus.disconnected;
    } else {
      state = NetworkStatus.connected;
    }
  }
}

final connectivityProvider =
    NotifierProvider<ConnectivityMonitor, NetworkStatus>(
  ConnectivityMonitor.new,
);
