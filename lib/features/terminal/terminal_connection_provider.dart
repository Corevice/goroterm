import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/navigation/navigator_key.dart';
import '../../core/ssh/connection_config.dart';
import '../../core/ssh/ssh_client_service.dart';
import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/ssh/known_hosts_store.dart';
import 'host_key_dialog.dart';

enum ConnectionStatus {
  connecting,
  connected,
  disconnected,
  reconnecting,
}

class TerminalConnectionState {
  const TerminalConnectionState({
    this.status = ConnectionStatus.disconnected,
    this.terminal,
    this.hostLabel,
    this.errorMessage,
    this.channelManager,
  });

  final ConnectionStatus status;
  final Terminal? terminal;
  final String? hostLabel;
  final String? errorMessage;
  final SshChannelManager? channelManager;

  TerminalConnectionState copyWith({
    ConnectionStatus? status,
    Terminal? terminal,
    String? hostLabel,
    String? errorMessage,
    SshChannelManager? channelManager,
    bool clearChannelManager = false,
  }) {
    return TerminalConnectionState(
      status: status ?? this.status,
      terminal: terminal ?? this.terminal,
      hostLabel: hostLabel ?? this.hostLabel,
      errorMessage: errorMessage ?? this.errorMessage,
      channelManager: clearChannelManager
          ? null
          : (channelManager ?? this.channelManager),
    );
  }
}

class TerminalConnectionNotifier
    extends FamilyNotifier<TerminalConnectionState, String> {
  SshClientService? _sshService;
  SshChannelManager? _channelManager;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _doneSubscription;
  ConnectionConfig? _config;
  String? _password;
  String? _privateKeyPem;
  String? _passphrase;
  bool _isCheckingConnection = false;
  Timer? _retryTimer;
  Timer? _healthCheckTimer;
  int _retryCount = 0;
  static const _maxRetries = 5;
  DateTime? _lastReconnectAttempt;
  DateTime? _lastAliveConfirmed;
  bool _isActiveKeepAliveRunning = false;
  int _keepAliveFailCount = 0;

  // Batch output buffer: accumulates SSH stdout chunks and flushes every 16 ms
  // to reduce UI thread work during high-throughput output.
  final StringBuffer _outputBuffer = StringBuffer();
  Timer? _flushTimer;

  @override
  TerminalConnectionState build(String arg) {
    ref.onDispose(_cleanup);
    // SSH 接続の生死は client.done のみで検知する
    // connectivity_plus は Android 実機で過剰発火するため使用しない
    return const TerminalConnectionState();
  }

  Future<void> connect({
    required ConnectionConfig config,
    String? password,
    String? privateKeyPem,
    String? passphrase,
  }) async {
    // 既に接続中または接続済みなら二重接続しない
    if (state.status == ConnectionStatus.connecting ||
        state.status == ConnectionStatus.connected) {
      return;
    }

    _config = config;
    _password = password;
    _privateKeyPem = privateKeyPem;
    _passphrase = passphrase;

    state = state.copyWith(
      status: ConnectionStatus.connecting,
      hostLabel: config.label.isEmpty ? config.host : config.label,
    );

    try {
      final terminal = await _connectCore(
        config: config,
        password: password,
        privateKeyPem: privateKeyPem,
        passphrase: passphrase,
      );
      _lastAliveConfirmed = DateTime.now();
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
    } catch (e) {
      _cleanupConnections(); // SSH クライアントとチャネルを確実に解放
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );
    }
  }

  /// Internal: establishes SSH connection, returns the Terminal to use.
  /// [existingTerminal] is reused on reconnect to preserve scroll-back buffer.
  Future<Terminal> _connectCore({
    required ConnectionConfig config,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    Terminal? existingTerminal,
  }) async {
    // 旧 done subscription を先にキャンセルしてレース条件を防ぐ
    _doneSubscription?.cancel();
    _doneSubscription = null;
    _sshService = SshClientService(knownHostsStore: KnownHostsStore());
    final client = await _sshService!.connect(
      config: config,
      password: password,
      privateKeyPem: privateKeyPem,
      passphrase: passphrase,
      onUnknownHostKey: (fingerprint) async {
        final ctx = globalNavigatorKey.currentContext;
        if (ctx == null) return false;
        return await showDialog<bool>(
              context: ctx,
              barrierDismissible: false,
              builder: (_) => UnknownHostKeyDialog(
                host: config.host,
                fingerprint: fingerprint,
              ),
            ) ??
            false;
      },
      onHostKeyMismatch: (storedFingerprint, actualFingerprint) async {
        final ctx = globalNavigatorKey.currentContext;
        if (ctx == null) return false;
        return await showDialog<bool>(
              context: ctx,
              barrierDismissible: false,
              builder: (_) => HostKeyMismatchDialog(
                host: config.host,
                storedFingerprint: storedFingerprint,
                actualFingerprint: actualFingerprint,
              ),
            ) ??
            false;
      },
    );

    _channelManager = SshChannelManager(client: client);

    final terminal = existingTerminal ??
        Terminal(
          maxLines: 10000,
          onOutput: (data) {
            _channelManager?.ptySession?.write(utf8.encoder.convert(data));
          },
          onResize: (width, height, pixelWidth, pixelHeight) {
            _channelManager?.resizePty(width, height);
          },
        );

    final session = await _channelManager!.openPtyChannel();

    _stdoutSubscription = session.stdout.listen((data) {
      _outputBuffer.write(utf8.decode(data, allowMalformed: true));
      _flushTimer ??= Timer(
        const Duration(milliseconds: 16),
        () => _flushOutput(terminal),
      );
    });

    // 現在のクライアント参照を保持し、古いクライアントの done イベントを無視する
    final currentClient = client;
    _doneSubscription = client.done.asStream().listen((_) {
      if (_sshService?.client == currentClient) {
        _onDisconnected();
      }
    });

    return terminal;
  }

  void _flushOutput(Terminal terminal) {
    _flushTimer = null;
    if (_outputBuffer.isNotEmpty) {
      terminal.write(_outputBuffer.toString());
      _outputBuffer.clear();
    }
  }

  void _onDisconnected() {
    // 再接続中なら無視（reconnect() が完了を処理する）
    if (state.status == ConnectionStatus.reconnecting) return;
    // 既に切断状態なら無視
    if (state.status == ConnectionStatus.disconnected) return;
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      errorMessage: 'Connection lost',
      clearChannelManager: true,
    );
    // 一時的なネットワーク不安定で PTY セッションを無駄に破棄しないよう、
    // 2 秒遅延してから接続状態を再確認して reconnect する。
    if (_config != null) {
      Future.delayed(const Duration(seconds: 2), () {
        // 遅延中に既に reconnect/connect が始まっていたら何もしない
        if (state.status == ConnectionStatus.reconnecting ||
            state.status == ConnectionStatus.connecting ||
            state.status == ConnectionStatus.connected) {
          return;
        }
        reconnect();
      });
    }
  }

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      lightHealthCheck();
    });
  }

  /// 軽量ヘルスチェック。isConnected フラグのみで判定し、
  /// exec チャネルを開くような重い操作は行わない。
  /// フォアグラウンドサービスの keepalive 受信時に呼ばれる。
  void lightHealthCheck() {
    // 接続中でなければ何もしない
    if (state.status != ConnectionStatus.connected) return;
    // isConnected が false なら切断を検知
    if (_sshService == null || !_sshService!.isConnected) {
      _onDisconnected();
    }
  }

  /// フォアグラウンドサービスの keepalive 受信時に呼ばれる。
  /// SSH 接続に軽量なコマンドを送信して接続を維持する。
  Future<void> activeKeepAlive() async {
    // unawaited で呼ばれるため重複実行を防ぐ
    if (_isActiveKeepAliveRunning) return;
    _isActiveKeepAliveRunning = true;
    try {
      await _activeKeepAliveCore();
    } finally {
      _isActiveKeepAliveRunning = false;
    }
  }

  Future<void> _activeKeepAliveCore() async {
    if (state.status == ConnectionStatus.connected) {
      final service = _sshService;
      if (service == null) return;
      final alive = await service.keepAlive();
      // await 中にサービスが差し替わった場合はタイムスタンプを更新しない
      if (alive && identical(service, _sshService) &&
          state.status == ConnectionStatus.connected) {
        _lastAliveConfirmed = DateTime.now();
        _keepAliveFailCount = 0;
      } else if (!alive) {
        // 1 回の失敗では再接続しない。一時的なネットワーク遅延を吸収する。
        // 連続 2 回失敗したら切断と判定する。
        _keepAliveFailCount++;
        if (_keepAliveFailCount >= 2) {
          _keepAliveFailCount = 0;
          _onDisconnected();
        }
      }
      return;
    }

    // disconnected 状態: リトライが尽きた後も定期的に再接続を試みる
    // 自動リトライのバックオフ中（_retryTimer が動いている）は干渉しない
    if (state.status == ConnectionStatus.disconnected &&
        _config != null &&
        _retryTimer == null &&
        _retryCount >= _maxRetries) {
      final now = DateTime.now();
      if (_lastReconnectAttempt != null &&
          now.difference(_lastReconnectAttempt!) <
              const Duration(seconds: 60)) {
        return;
      }
      _lastReconnectAttempt = now;
      _retryCount = 0;
      await reconnect();
    }
  }

  Future<void> checkConnection() async {
    // レース条件ガード: 既に checkConnection が実行中なら何もしない
    if (_isCheckingConnection) return;
    // 既に再接続中・接続中なら何もしない
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.connecting) return;
    // config がない（一度も接続していない）なら何もしない
    if (_config == null) return;

    _isCheckingConnection = true;
    try {
      // ケース B: バックグラウンド中に _onDisconnected() で disconnected になった場合
      // → 自動再接続を試みる（バナーが出ていても再接続）
      if (state.status == ConnectionStatus.disconnected) {
        await reconnect();
        return;
      }

      // ケース A: state が connected — 本当に生きているか確認
      if (_sshService != null && _sshService!.isConnected) {
        // 最後の確認から 45 秒以内なら probe をスキップ。
        // activeKeepAlive() が 30 秒ごとに _lastAliveConfirmed を更新するため、
        // 45 秒窓なら直近の keepalive 成功をカバーできる。
        if (_lastAliveConfirmed != null &&
            DateTime.now().difference(_lastAliveConfirmed!) <
                const Duration(seconds: 45)) {
          return;
        }

        // keepAlive() で生存確認。失敗した場合は 1 秒待ってリトライする。
        // バックグラウンド復帰直後は Wi-Fi が省電力モードから復帰するまで
        // 数秒かかるため、1 回の失敗で即座に再接続しない。
        final service = _sshService!;
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final alive = await service.keepAlive(
              executeTimeout: const Duration(seconds: 10),
              doneTimeout: const Duration(seconds: 10),
            );
            if (alive && identical(service, _sshService)) {
              _lastAliveConfirmed = DateTime.now();
              return; // 生きている
            }
          } catch (_) {
            // keepAlive 失敗
          }
          // 1 回目の失敗: Wi-Fi 復帰を待ってリトライ
          if (attempt == 0) {
            await Future.delayed(const Duration(seconds: 1));
            // 遅延中に状態が変わっていたら中断
            if (!identical(service, _sshService)) return;
          }
        }
      }

      // ゾンビ接続: state を disconnected に変更してから reconnect
      // （reconnect() は disconnected 状態でないと実行しないため）
      _cleanupConnections();
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
      await reconnect();
    } finally {
      _isCheckingConnection = false;
    }
  }

  Future<void> reconnect({bool isAutoRetry = false}) async {
    if (_config == null) return;
    // 既に接続中・再接続中・接続済みなら何もしない
    if (state.status == ConnectionStatus.connecting ||
        state.status == ConnectionStatus.reconnecting ||
        state.status == ConnectionStatus.connected) {
      return;
    }

    // 手動リトライの場合はカウンタをリセット
    if (!isAutoRetry) {
      _retryCount = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    }

    final existingTerminal = state.terminal;
    // UI に再接続中を表示
    state = state.copyWith(status: ConnectionStatus.reconnecting);

    // 古い接続を確実にクリーンアップ
    _cleanupConnections();
    // サーバーが古い接続を認識解除するまで少し待つ
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      final terminal = await _connectCore(
        config: _config!,
        password: _password,
        privateKeyPem: _privateKeyPem,
        passphrase: _passphrase,
        existingTerminal: existingTerminal,
      );
      if (existingTerminal != null) {
        terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
      }
      _retryCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _keepAliveFailCount = 0;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        terminal: existingTerminal,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );
      // 自動リトライ: 最大3回、指数バックオフ（2s, 4s, 8s）
      if (_retryCount < _maxRetries) {
        _retryCount++;
        final delay = Duration(seconds: 1 << _retryCount); // 2, 4, 8
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () {
          reconnect(isAutoRetry: true);
        });
      }
    }
  }

  /// Cancels SSH subscriptions and disposes resources without clearing state.
  void _cleanupConnections() {
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _outputBuffer.clear();
    _stdoutSubscription?.cancel();
    _doneSubscription?.cancel();
    _channelManager?.dispose();
    _sshService?.disconnect();
    _stdoutSubscription = null;
    _doneSubscription = null;
    _channelManager = null;
    _sshService = null;
  }

  void _cleanup() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _cleanupConnections();
  }
}

final terminalConnectionProvider = NotifierProvider.family<
    TerminalConnectionNotifier, TerminalConnectionState, String>(
  TerminalConnectionNotifier.new,
);
