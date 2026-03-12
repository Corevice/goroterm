---
goal: "Phase 39 - サイレント再接続の無限ループ修正 + keepalive ログ欠落の原因調査"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 39: サイレント再接続の無限ループ修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題

Phase 38 のログから以下の問題が判明:

### 1. `_silentReconnect` が無限ループに陥る

```
13:30:27 disconnected, attempting silent reconnect  ← 接続切れ
13:30:28 zombie connection, silent reconnect          ← checkConnection も発火
13:30:36 disconnected, attempting silent reconnect  ← また切断検知
13:30:40 zombie connection, silent reconnect
13:31:06 disconnected, attempting silent reconnect  ← 30秒ごとに繰り返し…
13:31:36 disconnected, attempting silent reconnect
13:32:29 disconnected, attempting silent reconnect
（永遠に続く）
```

**原因:** `_silentReconnect` にリトライ上限がない。接続 → 即切断 → 再接続のサイクルが無限に続く。
`silent reconnect succeeded` も `silent reconnect failed` もログに出ていないことから、
`_silentReconnect` のガード条件（state == reconnecting）でスキップされているか、
`_connectCore` 自体が成功した直後に `client.done` が発火して即座に `_onDisconnected` が呼ばれている。

### 2. keepalive tick ログが一つもない

8分間バックグラウンドにいたのに `[SSH] keepalive tick from service` が一度も記録されていない。
これは以下のいずれかを意味する:
- フォアグラウンドサービスが `sendDataToMain('keepalive')` を送信しているが main isolate に届いていない
- フォアグラウンドサービス自体がバックグラウンドで停止している
- `_onTaskData` が呼ばれていない

### 3. `_silentReconnect` と `checkConnection`/`reconnect` のレース条件

`_silentReconnect` が reconnecting に遷移した後、`checkConnection` の delayed callback（1500ms）が
発火して zombie 検知 → `_silentReconnect` を重複呼び出し。
同時に `_silentReconnect` の成功後に `client.done` が即発火 → `_onDisconnected` → 再度 `_silentReconnect`。

---

## 修正方針

### A) `_silentReconnect` にリトライ上限 + クールダウン

- 最大 3 回のサイレントリトライ
- 3 回失敗したら赤バナーを表示して通常の `reconnect`（指数バックオフ）に移行
- 最後の `_silentReconnect` 呼び出しから 5 秒以内は再呼び出しをブロック

### B) レース条件の排除

- `_silentReconnect` 実行中は `_onDisconnected` と `checkConnection` をブロック
- `_isSilentReconnecting` フラグで排他制御

### C) keepalive ログの強化

- `_onTaskData` のログを確実に出力（既にあるが動作確認のために詳細化）
- `activeKeepAlive` の開始/終了ログを追加
- `lightHealthCheck` のログを追加

---

## 実装手順

### ステップ 1: `_silentReconnect` にリトライ上限 + クールダウン + 排他フラグ

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

フィールド追加:

```dart
// BEFORE:
  bool _isActiveKeepAliveRunning = false;
  int _keepAliveFailCount = 0;
  String? _tmuxSessionName;

// AFTER:
  bool _isActiveKeepAliveRunning = false;
  int _keepAliveFailCount = 0;
  String? _tmuxSessionName;
  int _silentReconnectCount = 0;
  bool _isSilentReconnecting = false;
  DateTime? _lastSilentReconnectTime;
  static const _maxSilentRetries = 3;
  static const _silentReconnectCooldown = Duration(seconds: 5);
```

`_onDisconnected` に排他ガードを追加:

```dart
// BEFORE:
  void _onDisconnected() {
    if (state.status == ConnectionStatus.reconnecting) return;
    if (state.status == ConnectionStatus.disconnected) return;
    if (state.status == ConnectionStatus.connecting) return;
    AppLogger.instance.log('[SSH][$arg] disconnected, attempting silent reconnect');
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
    if (_config != null) {
      _silentReconnect();
    } else {
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
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
```

`_silentReconnect` にクールダウン + 排他制御 + カウンタ:

```dart
// BEFORE:
  Future<void> _silentReconnect() async {
    if (_config == null) {
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
        clearChannelManager: true,
      );
      return;
    }
    if (state.status == ConnectionStatus.reconnecting ||
        state.status == ConnectionStatus.connecting ||
        state.status == ConnectionStatus.connected) {
      return;
    }

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
    } catch (e) {
      AppLogger.instance.log('[SSH][$arg] silent reconnect failed: $e');
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        terminal: existingTerminal,
        errorMessage: e.toString(),
        clearChannelManager: true,
      );
      if (_retryCount < _maxRetries) {
        _retryCount++;
        final delay = Duration(seconds: 1 << _retryCount);
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () {
          reconnect(isAutoRetry: true);
        });
      }
    }
  }

// AFTER:
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
```

---

### ステップ 2: `checkConnection` のレース条件修正

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

`checkConnection` でも `_isSilentReconnecting` をチェックする。

```dart
// BEFORE (checkConnection 内、ゾンビ接続処理):
      AppLogger.instance.log('[SSH][$arg] zombie connection, silent reconnect');
      await _silentReconnect();

// AFTER:
      if (_isSilentReconnecting) {
        AppLogger.instance.log('[SSH][$arg] zombie detected but silent reconnect in progress');
        return;
      }
      AppLogger.instance.log('[SSH][$arg] zombie connection, silent reconnect');
      await _silentReconnect();
```

`checkConnection` の先頭にもガード追加:

```dart
// BEFORE:
    if (_isCheckingConnection) return;
    // 既に再接続中・接続中なら何もしない
    if (state.status == ConnectionStatus.reconnecting) return;

// AFTER:
    if (_isCheckingConnection) return;
    if (_isSilentReconnecting) return;
    if (state.status == ConnectionStatus.reconnecting) return;
```

---

### ステップ 3: keepalive 失敗時のサイレント再接続もガード

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

```dart
// BEFORE (_activeKeepAliveCore 内):
        if (_keepAliveFailCount >= 3) {
          _keepAliveFailCount = 0;
          AppLogger.instance.log('[SSH][$arg] keepalive failed 3 times, silent reconnect');
          _silentReconnect();
        }

// AFTER:
        if (_keepAliveFailCount >= 3) {
          _keepAliveFailCount = 0;
          if (!_isSilentReconnecting) {
            AppLogger.instance.log('[SSH][$arg] keepalive failed 3 times, triggering disconnect');
            _onDisconnected();
          }
        }
```

**注意:** keepalive 失敗からは `_onDisconnected` を経由させる。
`_onDisconnected` がリトライ上限を管理するため、直接 `_silentReconnect` を呼ばない。

---

### ステップ 4: `reconnect()` 成功時にカウンタリセット

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

通常の `reconnect()` で成功した場合もサイレントリトライカウンタをリセットする。

```dart
// BEFORE (reconnect 成功時):
      _retryCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _keepAliveFailCount = 0;

// AFTER:
      _retryCount = 0;
      _silentReconnectCount = 0;
      _lastReconnectAttempt = null;
      _lastAliveConfirmed = DateTime.now();
      _keepAliveFailCount = 0;
```

手動 `reconnect()` 呼び出し時（isAutoRetry == false）にもリセット:

```dart
// BEFORE (reconnect 内):
    // 手動リトライの場合はカウンタをリセット
    if (!isAutoRetry) {
      _retryCount = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    }

// AFTER:
    if (!isAutoRetry) {
      _retryCount = 0;
      _silentReconnectCount = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
```

---

### ステップ 5: keepalive ログの強化

**ファイル:** `lib/features/terminal/terminal_connection_provider.dart`

`activeKeepAlive` に開始ログを追加（頻繁すぎるので OK ログは維持しない）:

```dart
// BEFORE (activeKeepAlive):
  Future<void> activeKeepAlive() async {
    if (_isActiveKeepAliveRunning) return;
    _isActiveKeepAliveRunning = true;
    try {
      await _activeKeepAliveCore();
    } finally {
      _isActiveKeepAliveRunning = false;
    }
  }

// AFTER:
  Future<void> activeKeepAlive() async {
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
```

`_cleanupConnections` にもログ追加:

```dart
// BEFORE:
  void _cleanupConnections() {
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;

// AFTER:
  void _cleanupConnections() {
    AppLogger.instance.log('[SSH][$arg] cleaning up connections');
    _lastAliveConfirmed = null;
    _keepAliveFailCount = 0;
```

---

### ステップ 6: フォアグラウンドサービスのログ追加

**ファイル:** `lib/core/background/ssh_foreground_service.dart`

サービスの開始/停止をログに記録する。

```dart
// BEFORE:
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// AFTER:
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
```

```dart
// BEFORE (ensureRunning 内、サービス開始):
    if (!_running) {
      await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text,
        callback: _serviceCallback,
      );
      _running = true;

// AFTER:
    if (!_running) {
      debugPrint('[SSH] Starting foreground service');
      await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text,
        callback: _serviceCallback,
      );
      _running = true;
      debugPrint('[SSH] Foreground service started');
```

```dart
// BEFORE (stop):
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_running) return;
    await FlutterForegroundTask.stopService();
    _running = false;
  }

// AFTER:
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_running) return;
    debugPrint('[SSH] Stopping foreground service');
    await FlutterForegroundTask.stopService();
    _running = false;
  }
```

```dart
// BEFORE (_KeepAliveTaskHandler):
class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // サービス起動/再起動直後に即座に keepalive を送信
    FlutterForegroundTask.sendDataToMain('keepalive');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // メインイソレートに keepalive メッセージを送信
    // これによりメインイソレートのイベントループが活性化される
    FlutterForegroundTask.sendDataToMain('keepalive');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

// AFTER:
class _KeepAliveTaskHandler extends TaskHandler {
  int _tickCount = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[SSH][service] TaskHandler onStart');
    FlutterForegroundTask.sendDataToMain('keepalive');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _tickCount++;
    // 6回（60秒）に1回だけログ出力（頻繁すぎるとログが溢れる）
    if (_tickCount % 6 == 0) {
      debugPrint('[SSH][service] onRepeatEvent tick #$_tickCount');
    }
    FlutterForegroundTask.sendDataToMain('keepalive');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[SSH][service] TaskHandler onDestroy');
  }
}
```

**注意:** サービス isolate では `AppLogger` は使えない（別 isolate）。`debugPrint` を使って `adb logcat` で確認する。

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `lib/features/terminal/terminal_connection_provider.dart` | `_silentReconnect` にリトライ上限 3 回 + クールダウン 5 秒 + 排他フラグ、`_onDisconnected` で上限超過時に赤バナー + 通常 reconnect、`checkConnection` レース条件修正、ログ強化 |
| `lib/core/background/ssh_foreground_service.dart` | サービス開始/停止/tick のログ追加 + import 追加 |

---

## 検証項目

1. `~/flutter/bin/flutter analyze` — 静的解析エラーなし
2. `~/flutter/bin/flutter test` — 全テスト通過
3. `~/flutter/bin/flutter build apk --debug` — デバッグビルド成功
4. **手動テスト（デバイス）:**
   - 接続後バックグラウンド → 復帰: サイレント再接続が最大 3 回まで試行される
   - 3 回失敗したら赤バナー + 通常の指数バックオフリトライに移行
   - サイレント再接続が無限ループしない（ログで確認）
   - `adb logcat -s flutter | grep SSH` でサービス isolate のログが見える
   - 設定画面のログで `keepalive tick from service` が確認できる（フォアグラウンド時）
   - 手動「Reconnect」ボタンでサイレントリトライカウンタがリセットされる

---

## 技術的補足

### 無限ループの発生メカニズムと修正

**Phase 38（修正前）:**

```
client.done → _onDisconnected → _silentReconnect
  → _connectCore 成功 → state = connected
  → client.done 即発火（接続不安定）
  → _onDisconnected → _silentReconnect → ∞ループ
```

**Phase 39（修正後）:**

```
client.done → _onDisconnected → _silentReconnect (1/3)
  → _isSilentReconnecting = true（排他ロック）
  → _connectCore 成功 → state = connected
  → _isSilentReconnecting = false
  → client.done 即発火
  → _onDisconnected → _silentReconnect (2/3)  ← カウンタ増加
  → 失敗
  → _onDisconnected → _silentReconnect (3/3)
  → 失敗
  → _onDisconnected → 上限超過 → 赤バナー + 通常 reconnect（指数バックオフ 2s, 4s, 8s…）
```

### keepalive tick が記録されない原因の可能性

1. **フォアグラウンドサービス isolate が停止** — `onRepeatEvent` が呼ばれていない
   → `adb logcat` で `[SSH][service] onRepeatEvent` を確認
2. **`sendDataToMain` が失敗** — communication port の問題
   → `initCommunicationPort` は Phase 32 で追加済みだが、アプリが再起動した場合にリセットされる可能性
3. **main isolate がメッセージを処理していない** — イベントループがスロットルされている
   → サービス isolate のログは出るが main isolate のログは出ない場合、これが原因
