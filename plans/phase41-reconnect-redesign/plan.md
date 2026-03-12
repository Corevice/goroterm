---
goal: "Phase 41 - 再接続ロジックの根本的再設計（シンプル化 + tmux リアタッチ）"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 41: 再接続ロジックの根本的再設計

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題の根本原因

Phase 38-40 で導入した `_silentReconnect` は **一度も正常に動作していない**。

### 致命的バグ: `_silentReconnect` のガード条件

```dart
// _onDisconnected() は state を変更せずに _silentReconnect() を呼ぶ
// → state は connected のまま
void _onDisconnected() {
    ...
    _silentReconnect();  // state == connected で呼ぶ
}

Future<void> _silentReconnect() async {
    ...
    if (state.status == ConnectionStatus.connected) {
      return;  // ← ここで即 return。何もしない。
    }
    ...
}
```

結果:
- `_silentReconnect` は毎回即 return（"starting"/"succeeded"/"failed" が一度もログに出ない）
- `_onDisconnected` が state を disconnected にしないため、ループが続く
- `lightHealthCheck` が 30 秒ごとに `_onDisconnected` を呼び続ける
- `checkConnection` (app resume) が zombie 検知 → `_silentReconnect` → 何もしない

### 設計上の問題

Phase 38-40 の再接続機構は以下の要素が複雑に絡み合い、デバッグ不能:
- `_silentReconnect` / `_silentReconnectCount` / `_isSilentReconnecting`
- `_lastSilentReconnectTime` / `_silentReconnectCooldown`
- `_reconnectStabilityTimer` / `_lastReconnectSuccessTime`
- `_recentReconnectAttempts` / `_recentReconnectWindowStart` / `_isReconnectRateLimited`
- `reconnect` の `_retryCount` / `_retryTimer` / `_maxRetries`
- `checkConnection` の zombie 検知
- `activeKeepAlive` の `_keepAliveFailCount`
- `lightHealthCheck`
- `_startHealthCheck` の 30 秒タイマー
- `_scheduleCleanupCheck` の全タブ削除

**これらを全て撤去し、シンプルな 1 パスの再接続に置き換える。**

---

## 新しい設計

### 原則

1. **Android バックグラウンドで SSH 接続は必ず切れる** — これを前提とする
2. **切断検知したら即座に state = disconnected** — 中間状態を作らない
3. **再接続は 1 パスのみ** — disconnect → reconnect → 成功 or エラー表示
4. **フォアグラウンド復帰時に自動再接続** — checkConnection が唯一のトリガー
5. **tmux タブは自動リアタッチ** — reconnect 成功後に `tmux attach`

### フロー図

```
[client.done 発火 / keepAlive 失敗]
    ↓
_onDisconnected()
    ↓
state = disconnected（赤バナー非表示、ターミナルは保持）
    ↓
_attemptReconnect() を 1 回呼ぶ
    ↓
┌─ 成功 → state = connected
│         → tmux リアタッチ（tmux タブの場合）
│         → _startKeepAlive()
│
└─ 失敗 → state = disconnected + errorMessage
          → 「Reconnect」ボタン表示
          → 自動リトライ: 最大 3 回、指数バックオフ (3s, 6s, 12s)
          → 3 回失敗 → 停止、手動のみ

[アプリ復帰 (resumed)]
    ↓
checkConnection()
    ↓
state == disconnected → _attemptReconnect()
state == connected + keepAlive 失敗 → _onDisconnected()
state == connected + keepAlive 成功 → 何もしない
```

---

## 実装手順

### ステップ 1: フィールドの整理（不要なフィールド削除 + 新フィールド追加）

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
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
  String? _tmuxSessionName;
  int _silentReconnectCount = 0;
  bool _isSilentReconnecting = false;
  DateTime? _lastSilentReconnectTime;
  static const _maxSilentRetries = 3;
  static const _silentReconnectCooldown = Duration(seconds: 5);
  Timer? _reconnectStabilityTimer;
  DateTime? _lastReconnectSuccessTime;
  int _recentReconnectAttempts = 0;
  DateTime? _recentReconnectWindowStart;
  static const _maxRecentReconnectAttempts = 6;
  static const _recentReconnectWindow = Duration(minutes: 5);

// AFTER:
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

  // 再接続
  Timer? _retryTimer;
  int _retryCount = 0;
  static const _maxRetries = 3;
  bool _isReconnecting = false;

  // keepalive
  bool _isActiveKeepAliveRunning = false;
  int _keepAliveFailCount = 0;
```

---

### ステップ 2: `build` メソッドの cleanup を更新

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  @override
  TerminalConnectionState build(String arg) {
    ref.onDispose(_cleanup);
    // SSH 接続の生死は client.done のみで検知する
    // connectivity_plus は Android 実機で過剰発火するため使用しない
    return const TerminalConnectionState();
  }

// AFTER:
  @override
  TerminalConnectionState build(String arg) {
    ref.onDispose(_cleanup);
    return const TerminalConnectionState();
  }
```

---

### ステップ 3: `connect()` をシンプル化

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  Future<void> connect({
    required ConnectionConfig config,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    String? tmuxSessionName,
  }) async {
    // 既に接続中または接続済みなら二重接続しない
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
      _lastAliveConfirmed = DateTime.now();
      AppLogger.instance.log('[SSH][$arg] connected');
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
    } catch (e) {
      _cleanupConnections(); // SSH クライアントとチャネルを確実に解放
      AppLogger.instance.log('[SSH][$arg] connect failed: $e');
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );
    }
  }

// AFTER:
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
```

---

### ステップ 4: `_onDisconnected()` を書き直し

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  void _onDisconnected() {
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.disconnected) return;
    if (state.status == ConnectionStatus.connecting) return;
    // _silentReconnect 実行中は無視（成功後の stale done イベントの可能性）
    if (_isSilentReconnecting) {
      AppLogger.instance.log('[SSH][$arg] client.done during silent reconnect, ignoring');
      return;
    }
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    _reconnectStabilityTimer?.cancel();
    _reconnectStabilityTimer = null;

    // 急速切断検知: 前回の reconnect 成功から 30 秒以内の切断は
    // 「接続不安定」と判断し、カウンタをリセットしない
    if (_lastReconnectSuccessTime != null &&
        DateTime.now().difference(_lastReconnectSuccessTime!) < const Duration(seconds: 30)) {
      AppLogger.instance.log('[SSH][$arg] rapid disconnect detected (${DateTime.now().difference(_lastReconnectSuccessTime!).inSeconds}s after reconnect)');
    }
    _lastReconnectSuccessTime = null;

    // レートリミットチェック: 5 分以内に 6 回以上再接続試行したら停止
    if (_isReconnectRateLimited()) {
      _giveUpReconnect('Too many reconnect attempts');
      return;
    }

    if (_config != null && _silentReconnectCount < _maxSilentRetries) {
      AppLogger.instance.log('[SSH][$arg] disconnected, silent reconnect (${_silentReconnectCount + 1}/$_maxSilentRetries)');
      _silentReconnect();
    } else {
      _giveUpReconnect('Connection lost');
    }
  }

  /// 全ての自動再接続を停止し、赤バナー + 手動再接続ボタンを表示する。
  void _giveUpReconnect(String message) {
    AppLogger.instance.log('[SSH][$arg] giving up reconnect: $message');
    _silentReconnectCount = 0;
    _reconnectStabilityTimer?.cancel();
    _reconnectStabilityTimer = null;
    state = state.copyWith(
      status: ConnectionStatus.disconnected,
      errorMessage: message,
      clearChannelManager: true,
    );
    // 通常の reconnect（指数バックオフ）に移行
    if (_config != null) {
      _retryCount = 0;
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 2), () {
        reconnect(isAutoRetry: true);
      });
    }
  }

// AFTER:
  void _onDisconnected() {
    // 既に切断済み・再接続中なら何もしない
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
```

---

### ステップ 5: `_scheduleReconnect` と `_attemptReconnect` を新規追加

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

`_onDisconnected` メソッドの直後に追加:

```dart
// BEFORE:
  /// 赤バナーを出さずに即座に再接続を試みる。
  /// reconnecting 状態に遷移してスピナーのみ表示。
  /// 失敗した場合は _onDisconnected が次のリトライを判断する。
  Future<void> _silentReconnect() async {
    if (_config == null) {
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
      return;
    }
    // 排他制御: 既に実行中なら何もしない
    if (_isSilentReconnecting) return;
    if (state.status == ConnectionStatus.reconnecting ||
        state.status == ConnectionStatus.connecting ||
        state.status == ConnectionStatus.connected) {
      return;
    }

    // クールダウン: 前回の _silentReconnect から 5 秒以内は実行しない
    final now = DateTime.now();
    if (_lastSilentReconnectTime != null &&
        now.difference(_lastSilentReconnectTime!) < _silentReconnectCooldown) {
      AppLogger.instance.log('[SSH][$arg] silent reconnect cooldown, skipping');
      return;
    }

    _isSilentReconnecting = true;
    _silentReconnectCount++;
    _lastSilentReconnectTime = now;
    AppLogger.instance.log('[SSH][$arg] silent reconnect starting ($_silentReconnectCount/$_maxSilentRetries)');

    final existingTerminal = state.terminal;
    state = state.copyWith(
      status: ConnectionStatus.reconnecting,
      clearChannelManager: true,
    );

    _cleanupConnections();
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      final terminal = await _connectCore(
        config: _config!,
        password: _password,
        privateKeyPem: _privateKeyPem,
        passphrase: _passphrase,
        existingTerminal: existingTerminal,
      );
      AppLogger.instance.log('[SSH][$arg] silent reconnect succeeded');
      if (existingTerminal != null) {
        terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
      }
      _retryCount = 0;
      // _silentReconnectCount は即座にリセットしない。
      // 接続が 60 秒間安定してからリセットする。
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _lastReconnectSuccessTime = DateTime.now();
      _keepAliveFailCount = 0;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
      _startReconnectStabilityTimer();
      // tmux タブの場合は自動リアタッチ
      _autoReattachTmux(terminal);
    } catch (e) {
      AppLogger.instance.log('[SSH][$arg] silent reconnect failed: $e');
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        terminal: existingTerminal,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );
      // _onDisconnected が次のリトライを判断するので、ここではリトライしない
    } finally {
      _isSilentReconnecting = false;
    }
  }

// AFTER:
  /// 自動再接続をスケジュールする。指数バックオフ (3s, 6s, 12s)。
  void _scheduleReconnect() {
    if (_config == null) return;
    if (_retryCount >= _maxRetries) {
      AppLogger.instance.log('[SSH][$arg] max retries reached ($_maxRetries), stopping auto-reconnect');
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
      );
      return;
    }

    _retryCount++;
    final delay = Duration(seconds: _retryCount * 3); // 3s, 6s, 9s
    AppLogger.instance.log('[SSH][$arg] scheduling reconnect $_retryCount/$_maxRetries in ${delay.inSeconds}s');
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
```

---

### ステップ 6: `_autoReattachTmux` はそのまま維持

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

変更なし。既存のコードを維持:

```dart
  /// tmux タブの場合、再接続後に自動で tmux セッションにリアタッチする。
  void _autoReattachTmux(Terminal terminal) {
    if (_tmuxSessionName == null) return;
    AppLogger.instance.log('[SSH][$arg] auto-reattach tmux: $_tmuxSessionName');
    final escaped = _tmuxSessionName!.replaceAll("'", r"'\''");
    // 少し待ってからアタッチ（シェルの起動を待つ）
    Future.delayed(const Duration(milliseconds: 500), () {
      terminal.textInput("tmux attach -t '$escaped'\r");
    });
  }
```

---

### ステップ 7: `_startHealthCheck` と `lightHealthCheck` を削除

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

`_startHealthCheck` と `lightHealthCheck` を完全に削除する。
ヘルスチェックは `activeKeepAlive`（フォアグラウンドサービスの 10 秒タイマー）に一本化する。
30 秒タイマーの `lightHealthCheck` は `isConnected` フラグを見るだけで
ネットワークパケットを送信しないため、実際の接続生死を判定できない。
むしろ stale な `isConnected` で誤検知を起こすだけ。

```dart
// DELETE entirely:
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
```

---

### ステップ 8: `activeKeepAlive` をシンプル化

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  Future<void> activeKeepAlive() async {
    // unawaited で呼ばれるため重複実行を防ぐ
    if (_isActiveKeepAliveRunning) {
      AppLogger.instance.log('[SSH][$arg] activeKeepAlive skipped (already running)');
      return;
    }
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
      } else if (!alive && identical(service, _sshService)) {
        // 1〜2 回の失敗では再接続しない。一時的なネットワーク遅延を吸収する。
        // keepalive は 10 秒ごとに実行されるため、連続 3 回失敗（30 秒間応答なし）
        // で切断と判定する。
        // identical チェック: await 中に reconnect() で _sshService が差し替わった場合、
        // 古いサービスの失敗を新しい接続のカウンタに加算しない。
        _keepAliveFailCount++;
        AppLogger.instance.log('[SSH][$arg] keepalive FAILED ($_keepAliveFailCount)');
        if (_keepAliveFailCount >= 3) {
          _keepAliveFailCount = 0;
          if (!_isSilentReconnecting) {
            AppLogger.instance.log('[SSH][$arg] keepalive failed 3 times, triggering disconnect');
            _onDisconnected();
          }
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

// AFTER:
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
```

---

### ステップ 9: `checkConnection` をシンプル化

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  Future<void> checkConnection() async {
    // レース条件ガード: 既に checkConnection が実行中なら何もしない
    if (_isCheckingConnection) return;
    if (_isSilentReconnecting) return;
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

      if (_isSilentReconnecting) {
        AppLogger.instance.log('[SSH][$arg] zombie detected but silent reconnect in progress');
        return;
      }
      AppLogger.instance.log('[SSH][$arg] zombie connection, silent reconnect');
      await _silentReconnect();
    } finally {
      _isCheckingConnection = false;
    }
  }

// AFTER:
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
```

---

### ステップ 10: `reconnect()` を手動再接続専用に変更

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
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
      _silentReconnectCount = 0;
      _recentReconnectAttempts = 0;
      _recentReconnectWindowStart = null;
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
      AppLogger.instance.log('[SSH][$arg] reconnect succeeded');
      if (existingTerminal != null) {
        terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
      }
      _retryCount = 0;
      // _silentReconnectCount は即座にリセットしない。
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _lastReconnectSuccessTime = DateTime.now();
      _keepAliveFailCount = 0;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
      _startReconnectStabilityTimer();
      // tmux タブの場合は自動リアタッチ
      _autoReattachTmux(terminal);
    } catch (e) {
      AppLogger.instance.log('[SSH][$arg] reconnect failed: $e');
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

// AFTER:
  /// 手動の「Reconnect」ボタンから呼ばれる。リトライカウンタをリセットして再接続。
  Future<void> reconnect() async {
    if (_config == null) return;
    if (_isReconnecting) return;
    AppLogger.instance.log('[SSH][$arg] manual reconnect requested');
    _retryCount = 0;
    _retryTimer?.cancel();
    await _attemptReconnect();
  }
```

---

### ステップ 11: 不要メソッドの削除

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

以下のメソッドとフィールドを完全に削除する:

- `_silentReconnect()` メソッド全体
- `_startReconnectStabilityTimer()` メソッド全体（存在する場合）
- `_isReconnectRateLimited()` メソッド全体（存在する場合）
- `_giveUpReconnect()` メソッド全体（存在する場合）
- `_startHealthCheck()` メソッド全体
- `lightHealthCheck()` メソッド全体

フィールド:
- `_isCheckingConnection`
- `_healthCheckTimer`
- `_lastReconnectAttempt`
- `_lastAliveConfirmed`
- `_silentReconnectCount`
- `_isSilentReconnecting`
- `_lastSilentReconnectTime`
- `_maxSilentRetries`
- `_silentReconnectCooldown`
- `_reconnectStabilityTimer`（存在する場合）
- `_lastReconnectSuccessTime`（存在する場合）
- `_recentReconnectAttempts`（存在する場合）
- `_recentReconnectWindowStart`（存在する場合）
- `_maxRecentReconnectAttempts`（存在する場合）
- `_recentReconnectWindow`（存在する場合）

---

### ステップ 12: `_cleanupConnections` からヘルスチェックタイマー参照を削除

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _reconnectStabilityTimer?.cancel();
    _reconnectStabilityTimer = null;
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

// AFTER:
  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _keepAliveFailCount = 0;
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
```

---

### ステップ 13: `_cleanup` を更新

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  void _cleanup() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _reconnectStabilityTimer?.cancel();
    _reconnectStabilityTimer = null;
    _cleanupConnections();
  }

// AFTER:
  void _cleanup() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _cleanupConnections();
  }
```

---

### ステップ 14: テスト用メソッドを更新

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  @visibleForTesting
  void initConnectedStateForTesting({
    required SshClientService sshService,
    required TerminalConnectionState connectedState,
  }) {
    _sshService = sshService;
    _keepAliveFailCount = 0;
    state = connectedState;
  }

  /// テスト専用: _silentReconnectCount を直接設定する。
  /// Phase 39 のリトライ上限ロジックをテストするために使用する。
  @visibleForTesting
  void initSilentReconnectCountForTesting(int count) {
    _silentReconnectCount = count;
  }

// AFTER:
  @visibleForTesting
  void initConnectedStateForTesting({
    required SshClientService sshService,
    required TerminalConnectionState connectedState,
  }) {
    _sshService = sshService;
    _keepAliveFailCount = 0;
    state = connectedState;
  }
```

---

### ステップ 15: テストファイルの更新

`test/` 内で `lightHealthCheck`、`_silentReconnect`、`initSilentReconnectCountForTesting`、
`reconnect(isAutoRetry: true)` を参照しているテストがあれば修正する。

`reconnect()` は引数なしに変更されたので、呼び出し側から `isAutoRetry` パラメータを削除する。
`lightHealthCheck()` を呼んでいるテストは `activeKeepAlive()` に置き換えるか、削除する。
`initSilentReconnectCountForTesting` を使っているテストは削除する。

テストファイルを検索して、以下のパターンを修正:
- `lightHealthCheck` → 削除またはテスト自体を削除
- `reconnect(isAutoRetry:` → `reconnect()` に変更
- `initSilentReconnectCountForTesting` → テスト自体を削除
- `_silentReconnect` → テスト内で直接参照していないはずだが確認

---

### ステップ 16: `_scheduleCleanupCheck` の全タブ削除を無効化

**ファイル:** `lib/features/terminal/terminal_screen.dart`

再接続中にタブが削除されると UX が最悪になる。
全タブ削除のロジックを、disconnected かつ **errorMessage がある**（手動再接続に移行済み）
かつ **60 秒以上経過** した場合のみに変更する。

```dart
// BEFORE:
  void _scheduleCleanupCheck(int attempt) {
    if (attempt >= 18) return; // 最大 90 秒で打ち切り
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      final managerState = ref.read(sessionManagerProvider);
      if (managerState.sessions.isEmpty) return;

      // まだ再接続中のセッションがあれば待機
      final hasReconnecting = managerState.sessions.any((session) {
        final connState =
            ref.read(terminalConnectionProvider(session.sessionId));
        return connState.status == ConnectionStatus.reconnecting ||
            connState.status == ConnectionStatus.connecting;
      });

      if (hasReconnecting) {
        _scheduleCleanupCheck(attempt + 1);
        return;
      }

      // 全セッションが disconnected なら全タブを閉じる
      final allDisconnected = managerState.sessions.every((session) {
        final connState =
            ref.read(terminalConnectionProvider(session.sessionId));
        return connState.status == ConnectionStatus.disconnected;
      });

      if (allDisconnected) {
        final manager = ref.read(sessionManagerProvider.notifier);
        for (final session in [...managerState.sessions]) {
          manager.removeSession(session.sessionId);
        }
      }
    });
  }

// AFTER:
  void _scheduleCleanupCheck(int attempt) {
    // 再接続が試行されるため、自動でタブを閉じない。
    // ユーザーが手動でタブを閉じるか、接続画面に戻ることで対応する。
  }
```

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/features/terminal/terminal_connection_provider.dart` | 再接続ロジック全面書き直し: `_silentReconnect` / `lightHealthCheck` / `_startHealthCheck` / 関連フィールド削除、`_onDisconnected` → `_scheduleReconnect` → `_attemptReconnect` のシンプルなフロー、`checkConnection` 簡素化、`reconnect` は手動専用 |
| `lib/features/terminal/terminal_screen.dart` | `_scheduleCleanupCheck` を無効化（タブ自動削除を停止） |
| テストファイル | `lightHealthCheck` / `reconnect(isAutoRetry:)` / `initSilentReconnectCountForTesting` 参照を修正 |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - SSH 接続後 5 分バックグラウンド → 復帰: 自動再接続して入力可能になること
   - 再接続後にターミナルに `--- Reconnected ---` が表示されること
   - tmux 一覧から開いたタブ → バックグラウンド → 復帰: tmux セッションに自動リアタッチすること
   - 通常タブ → バックグラウンド → 復帰: 新しいシェルプロンプトが表示されること
   - 再接続 3 回失敗後は「Connection lost」バナー + 手動 Reconnect ボタンが表示されること
   - Reconnect ボタンを押すと再接続を試みること
   - ログに "reconnecting...", "reconnected successfully" or "reconnect failed" が明確に出ること
   - ログに "disconnected, silent reconnect (1/3)" が **出ない** こと（旧ロジック削除確認）

---

## 技術的補足

### なぜ Phase 38-40 の再接続が動かなかったか

```
_onDisconnected() {
    // state はまだ connected
    _silentReconnect();  // ← state == connected なので即 return
}

_silentReconnect() {
    if (state.status == ConnectionStatus.connected) return;  // ← ここ
    // 以下のコードは一度も実行されない
}
```

`_onDisconnected` が state を変更する前に `_silentReconnect` を呼んでいるため、
`_silentReconnect` のガード条件（`connected` 状態では再接続しない）に引っかかって即 return。
ログには "starting" も "succeeded" も "failed" も出ない。

新設計では `_onDisconnected` が **最初に** state を `disconnected` に変更し、
その後 `_scheduleReconnect` を呼ぶ。

### なぜ `lightHealthCheck` を削除するか

`lightHealthCheck` は `_sshService!.isConnected` フラグをチェックするだけ。
このフラグは Dart レベルの状態であり、以下の問題がある:

1. TCP 接続が切れても即座に `false` にならない（TCP FIN/RST を受信するまで）
2. バックグラウンドでは Dart イベントループが停止するため、FIN/RST の処理が遅延
3. 結果: 接続が死んでいるのに `isConnected = true` のまま → 誤検知なし
4. 逆: 接続が生きているのに `isConnected = false` → 誤検知（stale 状態）

`activeKeepAlive`（`execute('true')` で実際にパケットを送信）のほうが信頼性が高い。

### なぜ `_scheduleCleanupCheck` を無効化するか

現在のロジック: 全セッションが disconnected → 全タブを閉じる
問題: 再接続中は一時的に全セッションが disconnected になる → タブが消える → UX 最悪

再接続が成功してもタブが既に消えていたら意味がない。
ユーザーが明示的にタブを閉じるまでは保持する。
