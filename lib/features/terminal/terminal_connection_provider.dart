import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/error/app_error.dart';
import '../../core/navigation/navigator_key.dart';
import '../../core/network/connectivity_monitor.dart';
import '../../core/notification/notification_service.dart';
import '../../core/ssh/connection_config.dart';
import '../../core/ssh/ssh_client_service.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/shell_utils.dart';
import '../../core/ssh/ssh_channel_manager.dart';
import '../../core/ssh/known_hosts_store.dart';
import 'host_key_dialog.dart';
import 'session_manager.dart';

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
    this.shellExited = false,
  });

  final ConnectionStatus status;
  final Terminal? terminal;
  final String? hostLabel;
  final String? errorMessage;
  final SshChannelManager? channelManager;

  /// シェル（PTY）が正常終了したかどうか。
  /// `exit` コマンド等でシェルが終了すると true になる。
  final bool shellExited;

  TerminalConnectionState copyWith({
    ConnectionStatus? status,
    Terminal? terminal,
    String? hostLabel,
    String? errorMessage,
    SshChannelManager? channelManager,
    bool clearChannelManager = false,
    bool clearErrorMessage = false,
    bool? shellExited,
  }) {
    return TerminalConnectionState(
      status: status ?? this.status,
      terminal: terminal ?? this.terminal,
      hostLabel: hostLabel ?? this.hostLabel,
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      channelManager: clearChannelManager
          ? null
          : (channelManager ?? this.channelManager),
      shellExited: shellExited ?? this.shellExited,
    );
  }
}

class TerminalConnectionNotifier
    extends FamilyNotifier<TerminalConnectionState, String> {
  SshClientService? _sshService;
  SshChannelManager? _channelManager;
  StreamSubscription? _stdoutSubscription;
  bool _doneCancelled = false;
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


  // Batch output buffer: accumulates SSH stdout chunks and flushes periodically.
  // Each flush writes at most _flushChunkSize bytes to terminal.write().
  // If more data remains, the next flush is scheduled after a short delay
  // so the UI thread can render a frame between chunks.
  // This prevents blocking during heavy output (e.g. Claude Code on tmux).
  final StringBuffer _outputBuffer = StringBuffer();
  Timer? _flushTimer;
  static const int _flushChunkSize = 64 * 1024; // 64 KB per flush

  // リサイズ直後はチャンク分割を一時的に無効化する。
  // tmux のリドロー出力を分割すると表示崩れの原因になるため。
  Timer? _resizeGuardTimer;
  bool _resizeGuardActive = false;

  // コマンド完了通知: バックグラウンド時に出力が一定時間止まったら通知
  Timer? _idleNotifyTimer;
  int _outputBytesSinceLastIdle = 0;
  static const int _idleNotifyThresholdBytes = 4096; // tmuxステータス更新を除外するため十分大きく
  static const Duration _idleNotifyDelay = Duration(seconds: 30);
  static bool _isAppInBackground = false;
  /// 通知済みフラグ: 一度通知を送ったら、ユーザーがタブを確認するまで再通知しない
  bool _notificationSent = false;

  /// アプリのライフサイクル状態を更新する（TerminalScreen から呼ばれる）
  static void setAppInBackground(bool value) {
    _isAppInBackground = value;
  }

  /// ユーザーがこのタブを確認したことを記録し、通知済みフラグ＋バイトカウントをリセットする。
  void clearNotificationFlag() {
    _notificationSent = false;
    resetIdleCounter();
  }

  /// バックグラウンド移行時にバイトカウントをリセットする。
  /// フォアグラウンドで蓄積された出力量がバックグラウンドの通知判定に使われないようにする。
  void resetIdleCounter() {
    _outputBytesSinceLastIdle = 0;
    _idleNotifyTimer?.cancel();
    _idleNotifyTimer = null;
  }

  @override
  TerminalConnectionState build(String arg) {
    ref.onDispose(_cleanup);

    // ネットワークが disconnected → connected に遷移したとき、バックオフタイマーを
    // キャンセルして即座に再接続を試みる。これにより Wi-Fi 復旧後の待ち時間を解消する。
    ref.listen(connectivityProvider, (previous, next) {
      // `status == reconnecting` is intentionally excluded here: that state
      // always coincides with `_isReconnecting == true`, so the guard above
      // already prevents a double-attempt.  Only status == disconnected
      // (no retry in flight) needs the immediate-reconnect fast-path.
      if (previous == NetworkStatus.disconnected &&
          next == NetworkStatus.connected &&
          _config != null &&
          !_isReconnecting &&
          state.status == ConnectionStatus.disconnected) {
        AppLogger.instance
            .log('[SSH][$arg] network restored, reconnecting immediately');
        _retryCount = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
        _attemptReconnect();
      }
    });

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
      _setConnectedState(terminal);
    } catch (e) {
      _cleanupConnections();
      AppLogger.instance.log('[SSH][$arg] connect failed: $e');
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: e is AppError ? e.message : e.toString(),
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
    // 旧 done callback を先に無効化してレース条件を防ぐ
    _doneCancelled = true;
    _sshService = sshServiceFactoryOverride != null
        ? sshServiceFactoryOverride!()
        : SshClientService(knownHostsStore: KnownHostsStore());
    final client = await _sshService!.connect(
      config: config,
      password: password,
      privateKeyPem: privateKeyPem,
      passphrase: passphrase,
      onUnknownHostKey: (fingerprint) => _showHostKeyDialog(
        (_) => UnknownHostKeyDialog(
          host: config.host,
          fingerprint: fingerprint,
        ),
      ),
      onHostKeyMismatch: (storedFingerprint, actualFingerprint) =>
          _showHostKeyDialog(
        (_) => HostKeyMismatchDialog(
          host: config.host,
          storedFingerprint: storedFingerprint,
          actualFingerprint: actualFingerprint,
        ),
      ),
    );

    _channelManager = SshChannelManager(client: client);

    final terminal = existingTerminal ??
        Terminal(
          maxLines: 10000,
          onPrivateOSC: _handlePrivateOSC,
          onClipboardWrite: _handleClipboardWrite,
          onOutput: _onTerminalOutput,
          onResize: (width, height, pixelWidth, pixelHeight) {
            _channelManager?.resizePty(width, height);
            // リサイズ後 1500ms はチャンク分割を無効化
            // キーボード表示アニメーション中に複数回リサイズが発火するため
            // 十分な猶予を持たせて tmux リドロー出力の分割を防止
            _resizeGuardActive = true;
            _resizeGuardTimer?.cancel();
            _resizeGuardTimer = Timer(const Duration(milliseconds: 1500), () {
              _resizeGuardActive = false;
              _resizeGuardTimer = null;
            });
          },
        );

    final session = await _channelManager!.openPtyChannel();

    _shellOutputReceived = false;
    _stdoutSubscription = session.stdout.listen(
      (data) {
        _shellOutputReceived = true;
        _outputBuffer.write(utf8.decode(data, allowMalformed: true));
        _flushTimer ??= Timer(
          const Duration(milliseconds: 16),
          () => _flushOutput(terminal),
        );
        // コマンド完了通知: 出力量を追跡し、静止タイマーをリセット
        _outputBytesSinceLastIdle += data.length;
        _resetIdleNotifyTimer();
      },
      onDone: _onStdoutDone,
    );

    // 現在のクライアント参照を保持し、古いクライアントの done イベントを無視する。
    // Future はキャンセル不可のため _doneCancelled フラグで無効化する。
    final currentClient = client;
    _doneCancelled = false;
    client.done.whenComplete(() {
      if (!_doneCancelled && _sshService?.client == currentClient) {
        AppLogger.instance.log('[SSH][$arg] client.done fired');
        _onDisconnected();
      }
    });

    return terminal;
  }

  Future<bool> _showHostKeyDialog(Widget Function(BuildContext) builder) async {
    final ctx = globalNavigatorKey.currentContext;
    if (ctx == null) return false;
    return await showDialog<bool>(
          context: ctx,
          barrierDismissible: false,
          builder: builder,
        ) ??
        false;
  }

  void _flushOutput(Terminal terminal) {
    _flushTimer = null;
    if (_outputBuffer.isEmpty) return;

    final data = _outputBuffer.toString();

    // Alt buffer 使用中（Claude Code プランモード等の TUI アプリ）では
    // チャンク分割しない。分割すると ANSI エスケープシーケンスが途中で切れ、
    // 画面が中途半端な状態でスタックする原因になる。
    if (data.length <= _flushChunkSize ||
        _resizeGuardActive ||
        terminal.isUsingAltBuffer) {
      // Small output, resize guard active, or alt buffer (TUI): write all at once
      _outputBuffer.clear();
      terminal.write(data);
    } else {
      // Large output: write one chunk now, put the rest back,
      // and schedule the next chunk after a short delay so the
      // UI thread can process input events and render a frame.
      _outputBuffer.clear();
      terminal.write(data.substring(0, _flushChunkSize));
      _outputBuffer.write(data.substring(_flushChunkSize));
      _flushTimer = Timer(
        const Duration(milliseconds: 8),
        () => _flushOutput(terminal),
      );
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
  /// 最大10回までリトライし、それを超えたら諦める。
  void _scheduleReconnect() {
    if (_config == null) return;

    _retryCount++;
    if (_retryCount > 10) {
      AppLogger.instance.log('[SSH][$arg] max retries (10) reached, giving up');
      // Cancel the dangling timer from the 10th attempt so it does not fire
      // silently 30 s later and trigger an unexpected reconnect after giving up.
      _retryTimer?.cancel();
      _retryTimer = null;
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost. Tap to reconnect.',
      );
      return;
    }
    // 指数バックオフ: 3s → 6s → 12s → 24s → 30s（上限）
    // ビットシフト量を 10 に上限を設けることで AOT 環境での整数オーバーフローを防ぐ
    // (2^10 = 1024, 3*1024 = 3072 >> 30 なので上限には影響しない)
    final shift = (_retryCount - 1).clamp(0, 10);
    final delaySec = (3 * (1 << shift)).clamp(3, 30);
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
      _setConnectedState(terminal);
      _autoReattachTmux(terminal);
    } catch (e) {
      AppLogger.instance.log('[SSH][$arg] reconnect failed: $e');
      // _connectCore() が部分的に確立した接続リソースを即座に解放する。
      // connect() の catch と同様に _cleanupConnections() を呼ぶことで、
      // sshService/channelManager/stdoutSubscription 等をまとめて破棄する。
      _cleanupConnections();
      // terminal を保持したまま disconnected に遷移する。
      // errorMessage は直後の _scheduleReconnect() が設定するため、ここでは設定しない。
      // （設定しても即座に上書きされるだけで、生の例外テキストが一瞬表示される副作用がある）
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        terminal: existingTerminal,
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
    }).catchError((Object e) {
      // 再接続タイミングによっては resizePty 等が例外を投げる可能性がある。
      // unawaited のまま伝播させると未処理エラーになるため、ここでキャッチして
      // ログのみ残す（再接続フローへの影響はない）。
      AppLogger.instance.log('[SSH][$arg] auto-reattach error: $e');
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

      // keepAlive probe（2 回、Wi-Fi 復帰を待つ）
      // 1 回目
      final alive1 = await service.keepAlive(
        executeTimeout: const Duration(seconds: 5),
        doneTimeout: const Duration(seconds: 5),
      );
      if (!identical(service, _sshService)) return; // 差し替わった
      if (alive1) return; // 生きている

      // 1 回目の失敗: 1 秒待ってリトライ
      await Future.delayed(const Duration(seconds: 1));
      if (!identical(service, _sshService)) return; // 差し替わった

      // 2 回目
      final alive2 = await service.keepAlive(
        executeTimeout: const Duration(seconds: 5),
        doneTimeout: const Duration(seconds: 5),
      );
      if (!identical(service, _sshService)) return; // 差し替わった
      if (alive2) return; // 生きている

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

  /// テスト専用: _connectCore() 内で生成される SshClientService を置き換える。
  /// null の場合は実際の SshClientService が使われる。
  /// これにより実際のネットワーク接続なしに reconnect パスをテストできる。
  @visibleForTesting
  SshClientService Function()? sshServiceFactoryOverride;

  /// テスト専用: _scheduleReconnect() を直接呼び出す。
  /// 指数バックオフのステート変化をタイマー発火なしに検証するために使用する。
  @visibleForTesting
  void triggerScheduleReconnectForTesting() => _scheduleReconnect();

  /// テスト専用: _onDisconnected() を直接呼び出す。
  /// status が connecting / disconnected / _isReconnecting のガードをユニットテストで検証するために使用する。
  @visibleForTesting
  void triggerOnDisconnectedForTesting() => _onDisconnected();

  /// テスト専用: _isReconnecting フラグを直接設定する。
  /// _isReconnecting == true のガード（再接続中の二重切断防止）をテストするために使用する。
  @visibleForTesting
  void setIsReconnectingForTesting(bool value) => _isReconnecting = value;

  /// テスト専用: _sshService を null にする。
  /// checkConnection() の「_sshService == null → _onDisconnected()」パス (line 475-478) を
  /// 実際の SSH 接続なしにテストするために使用する。
  @visibleForTesting
  void clearSshServiceForTesting() => _sshService = null;

  /// テスト専用: _tmuxSessionName を直接設定する。
  /// _autoReattachTmux() の挙動を検証するために使用する。
  @visibleForTesting
  void setTmuxSessionNameForTesting(String? name) => _tmuxSessionName = name;

  /// テスト専用: _channelManager を直接注入する。
  /// _autoReattachTmux() の resizePty 呼び出しを mock で検証するために使用する。
  @visibleForTesting
  void setChannelManagerForTesting(SshChannelManager? manager) =>
      _channelManager = manager;

  /// テスト専用: _autoReattachTmux() を直接呼び出す。
  /// 再接続後の tmux リアタッチ挙動をテストするために使用する。
  @visibleForTesting
  void autoReattachTmuxForTesting(Terminal terminal) =>
      _autoReattachTmux(terminal);

  /// テスト専用: _setConnectedState() を直接呼び出す。
  /// connect() / _attemptReconnect() 成功パスの状態遷移を
  /// 実際の SSH 接続なしに検証するために使用する。
  @visibleForTesting
  void callSetConnectedStateForTesting(Terminal terminal) =>
      _setConnectedState(terminal);

  /// テスト専用: _keepAliveFailCount の現在値を返す。
  /// _setConnectedState() によるリセット後に値が 0 であることを検証するために使用する。
  @visibleForTesting
  int get keepAliveFailCountForTesting => _keepAliveFailCount;

  /// テスト専用: _isAppInBackground 静的フラグの現在値を返す。
  @visibleForTesting
  static bool get isAppInBackgroundForTesting => _isAppInBackground;

  /// テスト専用: _idleNotifyTimer がアクティブかどうかを返す。
  @visibleForTesting
  bool get isIdleTimerActiveForTesting => _idleNotifyTimer != null;

  /// テスト専用: _notificationSent フラグの現在値を返す。
  @visibleForTesting
  bool get isNotificationSentForTesting => _notificationSent;

  /// テスト専用: _notificationSent フラグを直接セットする。
  @visibleForTesting
  void setNotificationSentForTesting(bool value) => _notificationSent = value;

  /// テスト専用: _outputBytesSinceLastIdle に [n] バイトを加算し
  /// _resetIdleNotifyTimer() を呼び出す。stdoutSubscription からの出力受信を模倣する。
  @visibleForTesting
  void addOutputBytesForTesting(int n) {
    _outputBytesSinceLastIdle += n;
    _resetIdleNotifyTimer();
  }

  /// テスト専用: _resizeGuardActive を直接設定する。
  @visibleForTesting
  void setResizeGuardActiveForTesting(bool value) =>
      _resizeGuardActive = value;

  /// テスト専用: 出力バッファにデータをセットして _flushOutput を呼び出し、
  /// フラッシュ後の残バッファ内容を返す。
  /// 戻り値が空なら全データが書き込まれた、非空なら残りがある（チャンク分割）。
  @visibleForTesting
  String flushOutputForTesting(Terminal terminal, String data) {
    _outputBuffer.clear();
    _outputBuffer.write(data);
    _flushOutput(terminal);
    return _outputBuffer.toString();
  }

  /// PTY の stdout ストリームが閉じた（シェル終了 or ネットワーク断）際のコールバック。
  /// SSH 接続がまだ生きているかを確認し、生きていればシェルが正常終了したと判断する。
  void _onStdoutDone() {
    if (state.status == ConnectionStatus.connected &&
        (_sshService?.isConnected ?? false)) {
      AppLogger.instance.log('[SSH][$arg] shell exited (stdout done)');
      state = state.copyWith(shellExited: true);
    }
  }

  /// テスト専用: _stdoutSubscription の onDone コールバックを直接呼び出す。
  /// シェルの stdout ストリームが閉じた（PTY 終了）時の挙動をテストするために使用する。
  @visibleForTesting
  void triggerStdoutDoneForTesting() => _onStdoutDone();

  /// テスト専用: _handlePrivateOSC を直接呼び出す。
  /// OSC 52 クリップボード統合のユニットテストに使用する。
  @visibleForTesting
  void handlePrivateOscForTesting(String code, List<String> args) =>
      _handlePrivateOSC(code, args);

  /// Private OSC ハンドラ。OSC 52 はクリップボード書き込みに委譲する。
  void _handlePrivateOSC(String code, List<String> args) {
    AppLogger.instance.log('[SSH][$arg] onPrivateOSC: code=$code, args.length=${args.length}');
    final text = decodeOsc52Clipboard(code, args);
    if (text != null) {
      _handleClipboardWrite(text);
    }
  }

  /// OSC 52 クリップボード書き込みハンドラ。
  /// Claude Code の /copy コマンド等が ESC ] 52 ; c ; [base64] ST を送信し、
  /// xterm パーサーがデコード済みのテキストでこのコールバックを呼ぶ。
  void _handleClipboardWrite(String text) {
    Clipboard.setData(ClipboardData(text: text));
    AppLogger.instance.log('[SSH][$arg] OSC 52: copied ${text.length} chars to clipboard');
  }

  void _resetIdleNotifyTimer() {
    _idleNotifyTimer?.cancel();
    // フォアグラウンド時はタイマーを設定しない（バイトカウントのみ蓄積）
    if (!_isAppInBackground) return;
    if (_notificationSent) return;
    if (_outputBytesSinceLastIdle < _idleNotifyThresholdBytes) return;

    _idleNotifyTimer = Timer(_idleNotifyDelay, () {
      _idleNotifyTimer = null;
      if (_isAppInBackground &&
          !_notificationSent &&
          _outputBytesSinceLastIdle >= _idleNotifyThresholdBytes) {
        final host = _config?.host ?? 'server';
        // セッションマネージャからタブ名を取得
        final sessions = ref.read(sessionManagerProvider).sessions;
        final tabLabel = sessions
            .where((s) => s.sessionId == arg)
            .map((s) => s.label)
            .firstOrNull;
        NotificationService.instance.showCommandFinished(
          host: host,
          sessionId: arg,
          tabLabel: tabLabel,
        );
        _notificationSent = true;
      }
      _outputBytesSinceLastIdle = 0;
    });
  }

  /// Terminal.onOutput コールバック。
  void _onTerminalOutput(String data) {
    _channelManager?.ptySession?.write(utf8.encoder.convert(data));
  }

  /// 接続成功時に共通の状態遷移を行う。
  /// [connect] と [_attemptReconnect] の両パスで使用する。
  void _setConnectedState(Terminal terminal) {
    _retryCount = 0;
    _keepAliveFailCount = 0;
    // 再接続後も通知を送れるようにフラグをリセットする。
    // clearNotificationFlag() はユーザーがタブを確認したときに呼ばれるが、
    // 再接続（新しいシェルセッション開始）時にも通知フラグをリセットしないと、
    // 以前のセッションで通知を送った後の再接続時に通知が送られなくなる。
    _notificationSent = false;
    state = state.copyWith(
      status: ConnectionStatus.connected,
      terminal: terminal,
      channelManager: _channelManager,
      clearErrorMessage: true,
      shellExited: false,
    );
  }

  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _keepAliveFailCount = 0;
    _shellOutputReceived = false;
    resetIdleCounter();
    _flushTimer?.cancel();
    _flushTimer = null;
    _resizeGuardTimer?.cancel();
    _resizeGuardTimer = null;
    _resizeGuardActive = false;
    _outputBuffer.clear();
    _stdoutSubscription?.cancel();
    _doneCancelled = true;
    _channelManager?.dispose();
    try { _sshService?.disconnect(); } catch (_) {}
    _stdoutSubscription = null;
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

/// Decodes an OSC 52 clipboard write sequence.
///
/// Returns the decoded UTF-8 text, or null when:
///   - [code] is not '52'
///   - [args] has fewer than 2 elements
///   - [args[1]] (the base64 payload) is empty
///   - the base64 data cannot be decoded as valid UTF-8
///
/// This is a pure function exposed for unit testing without platform-channel
/// dependencies (Clipboard). The caller is responsible for writing the result
/// to the clipboard.
String? decodeOsc52Clipboard(String code, List<String> args) {
  if (code != '52') return null;
  if (args.length < 2) return null;
  final b64 = args[1];
  if (b64.isEmpty) return null;
  try {
    return utf8.decode(base64Decode(b64));
  } catch (_) {
    return null;
  }
}
