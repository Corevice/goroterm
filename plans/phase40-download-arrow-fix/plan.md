---
goal: "Phase 40 - 再接続ループ根本修正 + ダウンロードフリーズ修正 + 矢印ボタン感度改善"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 40: 再接続ループ根本修正 + ダウンロードフリーズ修正 + 矢印ボタン感度改善

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

### 問題 1（最重要）: 再接続が無限ループし、入力不能になる

Phase 39 で `_silentReconnectCount` と `_maxSilentRetries=3` を導入したが、
**reconnect 成功時に `_silentReconnectCount = 0` でリセットしている**ため、
カウンタが永久に 1/3 のままループする。

ログの証拠:

```
14:40:56 session_1_1 disconnected, silent reconnect (1/3)
14:41:01 session_1_1 disconnected, silent reconnect (1/3)  ← 常に 1/3
14:41:31 session_1_1 disconnected, silent reconnect (1/3)  ← 30秒ごとに繰り返し
14:42:01 session_1_1 disconnected, silent reconnect (1/3)
14:42:31 session_1_1 disconnected, silent reconnect (1/3)
（10分以上続く）
```

**ループの詳細メカニズム:**

```
1. 接続切断 → _onDisconnected → _silentReconnectCount=0 なので "(1/3)"
2. _silentReconnect 実行 → _connectCore で SSH ハンドシェイク成功
3. _silentReconnectCount = 0 にリセット（ここがバグ）
4. _startHealthCheck() 開始（30秒 Timer）
5. 接続が不安定で即座に切断 → client.done 発火
6. _onDisconnected → _silentReconnectCount=0 なのでまた "(1/3)"
7. → ステップ 2 に戻る（無限ループ）
```

さらに、ループ中に以下の副作用が発生:
- **新しいセッション ID が増殖**: session_1_3, _4, _5, _6, _7... が次々作成されて即死
- **ユーザーは入力不能**: terminal の PTY が切断状態のまま再接続を繰り返す
- **Authentication aborted エラー**: 並行する再接続試行が認証リソースを競合

### 問題 2: 重いファイルのダウンロードでアプリがフリーズする

`_downloadFileCore` で SSH stdout ストリームを受信する際、`Future.microtask` で yield しているが、
**microtask はイベントループの同じターン内で実行される**ため、実質的に UI スレッドに制御を返していない。

### 問題 3: ダウンロード中にバックグラウンドにすると黒画面でフリーズ

ダウンロード中にアプリをバックグラウンドにすると、`doneFallback` が最大 30 秒ブロックし、
フォアグラウンド復帰時に進捗状態が残ったまま UI がフリーズ。

### 問題 4: 矢印ボタンの感度が低すぎる

`_RepeatableActionButton` の `_activationDelay` が 150ms。
短いタップ（< 150ms）では `_startRepeat()` が発火前に `_stopRepeat()` で打ち消され、
**キー入力が全く送信されない**。

---

## 修正方針

### 問題 1 の修正: 再接続カウンタの遅延リセット + 急速切断検知

**根本修正:** `_silentReconnectCount` を reconnect 成功時に即座にリセットしない。
代わりに、接続が **60 秒間安定** してからリセットする。

**急速切断検知:** reconnect 成功から 30 秒以内に切断された場合、
「接続は不安定」と判断してカウンタを増加させる（リセットしない）。

**ハードリミット:** 5 分以内の再接続試行回数に上限（6 回）を設ける。
上限に達したら一切の自動再接続を停止し、赤バナー + 手動再接続ボタンのみ表示。

### 問題 2 の修正: yield を `Future.delayed(Duration.zero)` + 閾値縮小

### 問題 3 の修正: doneFallback 待機時間短縮 + エラー時進捗クリア

### 問題 4 の修正: タップ即時発火 + activationDelay 短縮

---

## 実装手順

### ステップ 1: 再接続カウンタの遅延リセット + 急速切断検知

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

フィールド変更:

```dart
// BEFORE:
  int _silentReconnectCount = 0;
  bool _isSilentReconnecting = false;
  DateTime? _lastSilentReconnectTime;
  static const _maxSilentRetries = 3;
  static const _silentReconnectCooldown = Duration(seconds: 5);

// AFTER:
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
```

---

### ステップ 2: `_silentReconnect` 成功時のカウンタリセットを遅延化

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE (_silentReconnect 内、成功時):
      AppLogger.instance.log('[SSH][$arg] silent reconnect succeeded');
      if (existingTerminal != null) {
        terminal.write('\r\n\x1B[33m--- Reconnected ---\x1B[0m\r\n');
      }
      _retryCount = 0;
      _silentReconnectCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _keepAliveFailCount = 0;
      state = state.copyWith(
        status: ConnectionStatus.connected,
        terminal: terminal,
        channelManager: _channelManager,
      );
      _startHealthCheck();
      // tmux タブの場合は自動リアタッチ
      _autoReattachTmux(terminal);

// AFTER:
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
```

同様に `reconnect()` 成功時も:

```dart
// BEFORE (reconnect 成功時):
      _retryCount = 0;
      _silentReconnectCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _keepAliveFailCount = 0;

// AFTER:
      _retryCount = 0;
      // _silentReconnectCount は即座にリセットしない。
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _lastReconnectSuccessTime = DateTime.now();
      _keepAliveFailCount = 0;
```

`reconnect` 成功時にも安定化タイマーを起動:

```dart
// BEFORE (reconnect 成功時、_startHealthCheck の後):
      _startHealthCheck();
      // tmux タブの場合は自動リアタッチ
      _autoReattachTmux(terminal);

// AFTER:
      _startHealthCheck();
      _startReconnectStabilityTimer();
      // tmux タブの場合は自動リアタッチ
      _autoReattachTmux(terminal);
```

---

### ステップ 3: 安定化タイマーと急速切断検知メソッドを追加

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

`_autoReattachTmux` メソッドの直後に追加:

```dart
// BEFORE:
  void _startHealthCheck() {

// AFTER:
  /// 再接続成功後、60 秒間接続が安定したら _silentReconnectCount をリセットする。
  /// 60 秒以内に切断されたらカウンタはリセットされず、次の切断で増加し続ける。
  void _startReconnectStabilityTimer() {
    _reconnectStabilityTimer?.cancel();
    _reconnectStabilityTimer = Timer(const Duration(seconds: 60), () {
      if (state.status == ConnectionStatus.connected) {
        AppLogger.instance.log('[SSH][$arg] connection stable for 60s, resetting reconnect counter');
        _silentReconnectCount = 0;
        _recentReconnectAttempts = 0;
        _recentReconnectWindowStart = null;
      }
    });
  }

  /// 5 分以内の再接続試行回数をチェックする。
  /// 上限（6 回）を超えたら全ての自動再接続を停止する。
  bool _isReconnectRateLimited() {
    final now = DateTime.now();
    // ウィンドウが古い場合はリセット
    if (_recentReconnectWindowStart != null &&
        now.difference(_recentReconnectWindowStart!) > _recentReconnectWindow) {
      _recentReconnectAttempts = 0;
      _recentReconnectWindowStart = null;
    }
    _recentReconnectWindowStart ??= now;
    _recentReconnectAttempts++;
    if (_recentReconnectAttempts > _maxRecentReconnectAttempts) {
      AppLogger.instance.log('[SSH][$arg] reconnect rate limited: $_recentReconnectAttempts attempts in 5 min');
      return true;
    }
    return false;
  }

  void _startHealthCheck() {
```

---

### ステップ 4: `_onDisconnected` に急速切断検知 + レートリミットを追加

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
    if (_config != null && _silentReconnectCount < _maxSilentRetries) {
      AppLogger.instance.log('[SSH][$arg] disconnected, silent reconnect (${_silentReconnectCount + 1}/$_maxSilentRetries)');
      _silentReconnect();
    } else {
      // サイレントリトライ上限超過 or config なし → 赤バナー表示
      AppLogger.instance.log('[SSH][$arg] disconnected, giving up silent reconnect');
      _silentReconnectCount = 0;
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
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
  }

// AFTER:
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
```

---

### ステップ 5: `reconnect()` の手動呼び出し時にカウンタ完全リセット

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE (reconnect 内):
    // 手動リトライの場合はカウンタをリセット
    if (!isAutoRetry) {
      _retryCount = 0;
      _silentReconnectCount = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    }

// AFTER:
    // 手動リトライの場合はカウンタを完全リセット
    if (!isAutoRetry) {
      _retryCount = 0;
      _silentReconnectCount = 0;
      _recentReconnectAttempts = 0;
      _recentReconnectWindowStart = null;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
```

---

### ステップ 6: `_cleanupConnections` で安定化タイマーもキャンセル

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

// AFTER:
  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _reconnectStabilityTimer?.cancel();
    _reconnectStabilityTimer = null;
```

---

### ステップ 7: `_cleanup` でも安定化タイマーをキャンセル

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE:
  void _cleanup() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _cleanupConnections();
  }

// AFTER:
  void _cleanup() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _reconnectStabilityTimer?.cancel();
    _reconnectStabilityTimer = null;
    _cleanupConnections();
  }
```

---

### ステップ 8: `connect()` 成功時の初期接続でもカウンタリセット

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

初回接続成功時はカウンタを明示的にリセットする（初期値は 0 だが明示的に）。

```dart
// BEFORE (connect 成功時):
      _lastAliveConfirmed = DateTime.now();
      AppLogger.instance.log('[SSH][$arg] connected');

// AFTER:
      _lastAliveConfirmed = DateTime.now();
      _silentReconnectCount = 0;
      _recentReconnectAttempts = 0;
      _recentReconnectWindowStart = null;
      AppLogger.instance.log('[SSH][$arg] connected');
```

---

### ステップ 9: yield を Future.delayed に変更 + 閾値縮小

**ファイル:** `lib/features/file_browser/file_browser_provider.dart`

```dart
// BEFORE:
      const yieldThreshold = 256 * 1024; // 256KB

// AFTER:
      const yieldThreshold = 64 * 1024; // 64KB
```

```dart
// BEFORE:
      // 256KB 受信ごとにストリームを一時停止し、
      // マイクロタスクで UI フレーム描画の時間を確保してから再開する。
      if (receivedSinceYield >= yieldThreshold) {
        receivedSinceYield = 0;
        subscription?.pause();
        Future.microtask(() {
          if (!completer.isCompleted) {
            subscription?.resume();
          }
        });
      }

// AFTER:
      // 64KB 受信ごとにストリームを一時停止し、
      // Timer キュー経由で UI フレーム描画の時間を確保してから再開する。
      // Future.delayed(Duration.zero) は Timer キューに入るため、
      // microtask と違いフレーム描画コールバックの実行機会がある。
      if (receivedSinceYield >= yieldThreshold) {
        receivedSinceYield = 0;
        subscription?.pause();
        Future<void>.delayed(Duration.zero, () {
          if (!completer.isCompleted) {
            subscription?.resume();
          }
        });
      }
```

---

### ステップ 10: doneFallback の最大待機時間を短縮

**ファイル:** `lib/features/file_browser/file_browser_provider.dart`

```dart
// BEFORE:
      // session.done フォールバック:
      // データ受信が止まってから 1 秒経過したら発動。
      // 大容量ファイルのバッファ drain に最大 30 秒待機。
      final doneFallback = execSession.done.then((_) async {
        var idleTicks = 0;
        var prev = received;
        for (var i = 0; i < 300 && !completer.isCompleted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (received == prev) {
            idleTicks++;
            if (idleTicks >= 10) break; // 1 秒間データなし → 発動
          } else {
            prev = received;
            idleTicks = 0;
          }
        }
        if (!completer.isCompleted) {
          streamError ??= NetworkError('Channel closed before stdout done');
          completer.complete();
        }
      });

// AFTER:
      // session.done フォールバック:
      // データ受信が止まってから 1 秒経過したら発動。
      // 大容量ファイルのバッファ drain に最大 5 秒待機。
      // バックグラウンド復帰時に長時間ブロックしないよう短縮。
      final doneFallback = execSession.done.then((_) async {
        var idleTicks = 0;
        var prev = received;
        for (var i = 0; i < 50 && !completer.isCompleted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (received == prev) {
            idleTicks++;
            if (idleTicks >= 10) break; // 1 秒間データなし → 発動
          } else {
            prev = received;
            idleTicks = 0;
          }
        }
        if (!completer.isCompleted) {
          streamError ??= NetworkError('Channel closed before stdout done');
          completer.complete();
        }
      });
```

---

### ステップ 11: ダウンロードエラー時の状態クリーンアップ強化

**ファイル:** `lib/features/file_browser/file_browser_provider.dart`

```dart
// BEFORE:
  Future<void> downloadFile(String remotePath) async {
    if (_isDownloading) return;
    _isDownloading = true;
    final baseState = state.valueOrNull ?? const FileBrowserState();
    try {
      await _downloadFileCore(remotePath, baseState);
    } catch (e) {
      debugPrint('downloadFile error: $e');
    } finally {
      _isDownloading = false;
      final cur = state.valueOrNull;
      if (cur != null && cur.downloadProgress != null) {
        state = AsyncData(cur.copyWith(downloadProgress: null));
      }
      // ダウンロード終了後、接続が切れていたら AsyncError に遷移
      if (_channelManager == null) {
        state = AsyncError(NetworkError('SSH not connected'), StackTrace.current);
      }
    }
  }

// AFTER:
  Future<void> downloadFile(String remotePath) async {
    if (_isDownloading) return;
    _isDownloading = true;
    final baseState = state.valueOrNull ?? const FileBrowserState();
    try {
      await _downloadFileCore(remotePath, baseState);
    } catch (e) {
      debugPrint('downloadFile error: $e');
      // エラー時は進捗を即座にクリアし、ファイルブラウザを操作可能な状態に戻す
      final cur = state.valueOrNull;
      if (cur != null) {
        state = AsyncData(cur.copyWith(downloadProgress: null));
      }
    } finally {
      _isDownloading = false;
      final cur = state.valueOrNull;
      if (cur != null && cur.downloadProgress != null) {
        state = AsyncData(cur.copyWith(downloadProgress: null));
      }
      // ダウンロード終了後、接続が切れていたら AsyncError に遷移
      if (_channelManager == null) {
        state = AsyncError(NetworkError('SSH not connected'), StackTrace.current);
      }
    }
  }
```

---

### ステップ 12: 矢印ボタンの即時タップ対応

**ファイル:** `lib/widgets/quick_action_bar.dart`

```dart
// BEFORE:
  void _stopRepeat() {
    _activationTimer?.cancel();
    _activationTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _downPosition = null;
    if (mounted) {
      setState(() => _isPressed = false);
    }
  }

// AFTER:
  void _stopRepeat() {
    final wasPendingActivation = _activationTimer?.isActive ?? false;
    _activationTimer?.cancel();
    _activationTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _downPosition = null;
    // タイマー発火前の短いタップでも 1 回キー送信する。
    // _isCancelled（スクロール操作）の場合は送信しない。
    // _isPressed が false = まだ _startRepeat が呼ばれていない = タップが短い
    if (wasPendingActivation && !_isCancelled && !_isPressed && mounted) {
      widget.onPressed();
    }
    if (mounted) {
      setState(() => _isPressed = false);
    }
  }
```

---

### ステップ 13: activationDelay を短縮

**ファイル:** `lib/widgets/quick_action_bar.dart`

```dart
// BEFORE:
  // ボタン押下と判定するまでの遅延
  static const _activationDelay = Duration(milliseconds: 150);

// AFTER:
  // ボタン押下と判定するまでの遅延（長押しリピート開始）
  static const _activationDelay = Duration(milliseconds: 80);
```

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/features/terminal/terminal_connection_provider.dart` | カウンタ遅延リセット（60秒安定化タイマー）、急速切断検知（30秒以内の切断）、レートリミット（5分6回上限）、`_giveUpReconnect` メソッド追加、`_startReconnectStabilityTimer` / `_isReconnectRateLimited` メソッド追加、cleanup にタイマーキャンセル追加 |
| `lib/features/file_browser/file_browser_provider.dart` | yield を microtask→delayed に変更、閾値 256→64KB、doneFallback 30→5秒、エラー時進捗クリア |
| `lib/widgets/quick_action_bar.dart` | タップ即時発火 + activationDelay 150→80ms |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - SSH 接続後バックグラウンド → 復帰: 再接続ループが 3 回以内で停止すること
   - 3 回失敗後は赤バナー + 手動再接続ボタンが表示されること
   - 手動再接続ボタンを押すとカウンタがリセットされ再接続できること
   - 再接続成功後 60 秒安定でカウンタがリセットされること（ログで確認）
   - 5 分以内に 6 回以上再接続すると自動で停止すること
   - 100MB+ のファイルをダウンロード → UI がフリーズせず進捗バーが更新されること
   - ダウンロード中にバックグラウンド → 復帰時に黒画面にならないこと
   - 矢印ボタンを素早くタップ → 即座にキー入力が送信されること
   - 矢印ボタンを長押し → リピート入力が発生すること
   - ショートカットバーを横スクロール中 → 矢印ボタンが誤発火しないこと

---

## 技術的補足

### なぜカウンタを即座にリセットしてはいけないか

Phase 39 の実装:
```
reconnect成功 → _silentReconnectCount = 0 → 即切断 → (1/3) → reconnect成功 → count=0 → ∞
```

Phase 40 の修正:
```
reconnect成功 → count はそのまま → 60秒タイマー開始
  → 60秒安定 → count = 0（正常リセット）
  → 30秒以内に切断 → count はそのまま → (2/3) → reconnect
  → また即切断 → (3/3) → 上限 → 赤バナー表示
```

### レートリミットの必要性

`_silentReconnect` のカウンタだけでは、以下のパスで無限ループが残る:
- silent reconnect 3 回失敗 → `_giveUpReconnect` → `reconnect(isAutoRetry: true)`
- reconnect 失敗 → backoff → reconnect → 失敗 → _maxRetries(5) で停止
- activeKeepAlive の定期実行が `_retryCount >= _maxRetries` のパスで `reconnect()` を呼ぶ（60秒間隔）
- reconnect 成功 → 即切断 → _onDisconnected → silent reconnect 3回 → reconnect → ...

レートリミット（5分6回）はこの全パスをカバーするハードキャップとして機能する。

### Future.microtask vs Future.delayed(Duration.zero)

Dart イベントループの実行順序:
1. **Microtask キュー** — `Future.microtask`, `scheduleMicrotask`, `then`
2. **Event キュー** — `Timer`, `Future.delayed`, I/O, **フレーム描画**

`Future.microtask` → フレーム描画より先に実行 → UI フリーズ
`Future.delayed(Duration.zero)` → フレーム描画と同じ優先度 → UI 更新可能
