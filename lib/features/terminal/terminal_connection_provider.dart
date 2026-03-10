import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/navigation/navigator_key.dart';
import '../../core/ssh/connection_config.dart';
import '../../core/ssh/ssh_client_service.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/shell_utils.dart';
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
  String? _tmuxSessionName;
  bool _shellOutputReceived = false;

  // shell-ready 待機
  static const _shellReadyInitialDelay = Duration(milliseconds: 300);
  static const _shellReadyPollInterval = Duration(milliseconds: 100);
  static const _shellReadyMaxPolls = 47; // 300ms + 47×100ms ≈ 5s

  // 再接続（無制限リトライ + 指数バックオフ、最大30秒）
  Timer? _retryTimer;
  int _retryCount = 0;
  bool _isReconnecting = false;

  // keepalive
  bool _isActiveKeepAliveRunning = false;
  int _keepAliveFailCount = 0;

  // Batch output buffer: accumulates SSH stdout chunks and flushes every 16 ms
  // to reduce UI thread work during high-throughput output.
  final StringBuffer _outputBuffer = StringBuffer();
  Timer? _flushTimer;

  @override
  TerminalConnectionState build(String arg) {
    ref.onDispose(_cleanup);
    return const TerminalConnectionState();
  }

  Future<void> connect({
    required ConnectionConfig config,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    String? tmuxSessionName,
  }) async {
    if (state.status == ConnectionStatus.connecting ||
        state.status == ConnectionStatus.connected) {
      return;
    }

    _tmuxSessionName = tmuxSessionName;
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
      AppLogger.instance.log('[SSH][$arg] connected');
      _retryCount = 0;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
    } catch (e) {
      _cleanupConnections();
      AppLogger.instance.log('[SSH][$arg] connect failed: $e');
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

    _shellOutputReceived = false;
    _stdoutSubscription = session.stdout.listen((data) {
      _shellOutputReceived = true;
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
        AppLogger.instance.log('[SSH][$arg] client.done fired');
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
    // 既に切断済み・接続中なら何もしない
    if (state.status == ConnectionStatus.disconnected) return;
    if (state.status == ConnectionStatus.connecting) return;
    if (_isReconnecting) {
      AppLogger.instance.log('[SSH][$arg] disconnect during reconnect, ignoring');
      return;
    }

    AppLogger.instance.log('[SSH][$arg] disconnected');
    _keepAliveFailCount = 0;
    _cleanupConnections();

    // ターミナルは保持したまま disconnected に遷移
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      clearChannelManager: true,
    );

    // 自動再接続を試みる
    _scheduleReconnect();
  }

  /// 自動再接続をスケジュールする。指数バックオフ (3s, 6s, 12s, 24s, 30s, 30s, ...)。
  /// リトライ回数に上限はなく、接続が復活するまで試行し続ける。
  void _scheduleReconnect() {
    if (_config == null) return;

    _retryCount++;
    // 指数バックオフ: 3s → 6s → 12s → 24s → 30s（上限）
    final delaySec = (3 * (1 << (_retryCount - 1))).clamp(3, 30);
    final delay = Duration(seconds: delaySec);
    AppLogger.instance.log('[SSH][$arg] scheduling reconnect #$_retryCount in ${delay.inSeconds}s');

    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      errorMessage: 'Reconnecting in ${delay.inSeconds}s... (attempt #$_retryCount)',
    );

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _attemptReconnect();
    });
  }

  /// 再接続を 1 回試みる。成功時は tmux リアタッチも行う。
  Future<void> _attemptReconnect() async {
    if (_config == null) return;
    if (_isReconnecting) return;
    if (state.status == ConnectionStatus.connected) return;

    _isReconnecting = true;
    final existingTerminal = state.terminal;

    state = state.copyWith(
      status: ConnectionStatus.reconnecting,
      clearChannelManager: true,
    );

    // 古い接続がまだ残っている場合に備えてクリーンアップ
    _cleanupConnections();

    try {
      AppLogger.instance.log('[SSH][$arg] reconnecting...');
      final terminal = await _connectCore(
        config: _config!,
        password: _password,
        privateKeyPem: _privateKeyPem,
        passphrase: _passphrase,
        existingTerminal: existingTerminal,
      );

      AppLogger.instance.log('[SSH][$arg] reconnected successfully');
      if (existingTerminal != null) {
        terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
      }
      _retryCount = 0;
      _keepAliveFailCount = 0;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _autoReattachTmux(terminal);
    } catch (e) {
      AppLogger.instance.log('[SSH][$arg] reconnect failed: $e');
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        terminal: existingTerminal,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );
      // 次のリトライをスケジュール
      _scheduleReconnect();
    } finally {
      _isReconnecting = false;
    }
  }

  /// tmux タブの場合、再接続後に自動で tmux セッションにリアタッチする。
  /// PTY の stdout からデータを受信するまで待機してからコマンドを送信する。
  /// これによりシェルの初期化（.bashrc 等）が完了してから attach する。
  void _autoReattachTmux(Terminal terminal) {
    if (_tmuxSessionName == null) return;
    AppLogger.instance.log('[SSH][$arg] auto-reattach tmux: $_tmuxSessionName');
    final cmd = 'tmux attach -t ${shellQuote(_tmuxSessionName!)}\r';

    // シェルが ready（stdout に何か出力した）になるまで待機してからコマンドを送信。
    unawaited(waitForShellReady().then((_) async {
      AppLogger.instance.log(
          '[SSH][$arg] sending tmux attach (shellReady=$_shellOutputReceived)');
      terminal.textInput(cmd);

      // tmux attach 後、PTY のウィンドウサイズを再送信する。
      // 再接続時は PTY が新規作成されるため、tmux が認識しているサイズと
      // 実際の端末サイズが不一致になり表示が崩れる。
      // 少し待ってから現在のサイズを送ることで tmux に再描画させる。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final w = terminal.viewWidth;
      final h = terminal.viewHeight;
      if (w > 0 && h > 0) {
        _channelManager?.resizePty(w, h);
        AppLogger.instance.log('[SSH][$arg] resized PTY after tmux attach: ${w}x$h');
      }
    }));
  }

  /// シェルが stdout に何か出力したかどうか。
  /// tmux attach のタイミング判定に使用。
  bool get shellOutputReceived => _shellOutputReceived;

  /// シェルが ready（stdout に何か出力した）になるまで待機する。
  /// 最小 [_shellReadyInitialDelay] + 最大 [_shellReadyMaxPolls] × [_shellReadyPollInterval] ≈ 5 秒。
  /// 接続が切れた場合は即座に返る。
  Future<void> waitForShellReady() async {
    await Future<void>.delayed(_shellReadyInitialDelay);
    for (var i = 0; i < _shellReadyMaxPolls; i++) {
      if (_shellOutputReceived) break;
      if (!(_sshService?.isConnected ?? false)) break;
      await Future<void>.delayed(_shellReadyPollInterval);
    }
  }

  @visibleForTesting
  void markShellReadyForTesting() => _shellOutputReceived = true;

  /// フォアグラウンドサービスの keepalive 受信時に呼ばれる。
  /// SSH exec チャネルで軽量コマンドを送信して接続を維持する。
  Future<void> activeKeepAlive() async {
    if (_isActiveKeepAliveRunning) return;
    _isActiveKeepAliveRunning = true;
    try {
      await _activeKeepAliveCore();
    } finally {
      _isActiveKeepAliveRunning = false;
    }
  }

  Future<void> _activeKeepAliveCore() async {
    if (state.status != ConnectionStatus.connected) return;
    final service = _sshService;
    if (service == null) return;

    final alive = await service.keepAlive();

    // await 中にサービスが差し替わった場合は無視
    if (!identical(service, _sshService)) return;
    if (state.status != ConnectionStatus.connected) return;

    if (alive) {
      _keepAliveFailCount = 0;
    } else {
      _keepAliveFailCount++;
      AppLogger.instance.log('[SSH][$arg] keepalive failed ($_keepAliveFailCount/3)');
      if (_keepAliveFailCount >= 3) {
        AppLogger.instance.log('[SSH][$arg] keepalive failed 3 times, disconnecting');
        _keepAliveFailCount = 0;
        _onDisconnected();
      }
    }
  }

  /// アプリ復帰時に呼ばれる。接続状態を確認し、必要に応じて再接続する。
  Future<void> checkConnection() async {
    if (_isReconnecting) return;
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.connecting) return;
    if (_config == null) return;

    // ケース 1: 既に disconnected → 再接続を試みる
    if (state.status == ConnectionStatus.disconnected) {
      AppLogger.instance.log('[SSH][$arg] app resumed, reconnecting (was disconnected)');
      _retryCount = 0; // app resume 時はリトライカウンタをリセット
      _retryTimer?.cancel();
      await _attemptReconnect();
      return;
    }

    // ケース 2: connected → keepAlive で生存確認
    if (state.status == ConnectionStatus.connected) {
      final service = _sshService;
      if (service == null) {
        _onDisconnected();
        return;
      }

      // keepAlive probe（最大 2 回、Wi-Fi 復帰を待つ）
      for (var attempt = 0; attempt < 2; attempt++) {
        final alive = await service.keepAlive(
          executeTimeout: const Duration(seconds: 5),
          doneTimeout: const Duration(seconds: 5),
        );
        if (!identical(service, _sshService)) return; // 差し替わった
        if (alive) return; // 生きている

        // 1 回目の失敗: 1 秒待ってリトライ
        if (attempt == 0) {
          await Future.delayed(const Duration(seconds: 1));
          if (!identical(service, _sshService)) return;
        }
      }

      // 2 回とも失敗 → 切断
      AppLogger.instance.log('[SSH][$arg] app resumed, connection dead, reconnecting');
      _onDisconnected();
    }
  }

  /// 手動の「Reconnect」ボタンから呼ばれる。リトライカウンタをリセットして再接続。
  Future<void> reconnect() async {
    if (_config == null) return;
    if (_isReconnecting) return;
    AppLogger.instance.log('[SSH][$arg] manual reconnect requested');
    _retryCount = 0;
    _retryTimer?.cancel();
    await _attemptReconnect();
  }

  /// テスト専用: SSH サービスインスタンスと接続状態を直接設定する。
  /// 実際の SSH 接続を確立せずに keepAlive / checkConnection 挙動をテストするために使用する。
  /// [config] を指定すると _config も設定され、checkConnection() の config ガードを通過できる。
  @visibleForTesting
  void initConnectedStateForTesting({
    required SshClientService sshService,
    required TerminalConnectionState connectedState,
    ConnectionConfig? config,
  }) {
    _sshService = sshService;
    _keepAliveFailCount = 0;
    if (config != null) _config = config;
    state = connectedState;
  }

  /// Cancels SSH subscriptions and disposes resources without clearing state.
  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _keepAliveFailCount = 0;
    _shellOutputReceived = false;
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
