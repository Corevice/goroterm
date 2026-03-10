---
goal: "Phase 18 - バックグラウンド接続維持の強化（即時再接続 + 定期ヘルスチェック + サービスイベント連携）"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 18: バックグラウンド接続維持の強化

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 15 で auto-reconnect のステートマシンバグを修正し、バッテリー最適化の無効化要求を追加したが、少し長めにバックグラウンドにいると接続が切れる問題が解消していない。

## 根本原因分析

### 原因 1: _onDisconnected() がバックグラウンドで即時再接続しない（致命的）

`_onDisconnected()` は `client.done` 発火時に呼ばれるが、state を `disconnected` に変更するだけで**自動再接続を試みない**。再接続は `checkConnection()` でのみ行われ、`checkConnection()` はフォアグラウンド復帰時の `didChangeAppLifecycleState(resumed)` でのみ呼ばれる。

つまり:
1. バックグラウンド中に SSH keepalive が失敗 → `client.done` 発火 → `_onDisconnected()`
2. state が `disconnected` になるが、**再接続を試みない**
3. フォアグラウンドサービスはまだ動いていてプロセスは生きている
4. ユーザーが復帰するまで何もしない → 復帰時に `checkConnection()` → `reconnect()`
5. この時点でもうかなり時間が経っているので、reconnect 自体にも時間がかかるか失敗する

**修正**: `_onDisconnected()` で即座に `reconnect()` を呼ぶ。バックグラウンドでもプロセスが生きている限り再接続を試みる。

### 原因 2: Dart イベントループがスリープして keepalive が遅延する

フォアグラウンドサービスの `eventAction: ForegroundTaskEventAction.nothing()` により、サービスイソレートは何もしない。メインイソレートの Dart イベントループが OS により throttle されると、dartssh2 の keepalive タイマー（10 秒間隔）が予定通りに発火せず、サーバー側がタイムアウトする。

**修正**: フォアグラウンドサービスの `eventAction` を `repeat(interval: 30000)` に変更し、`onRepeatEvent` からメインイソレートにメッセージを送信。メインイソレート側でメッセージ受信時にヘルスチェックを行う。サービスイソレートの定期イベントが間接的にメインイソレートを「起こす」効果がある。

### 原因 3: 定期的なヘルスチェックがない

接続の死活確認は `checkConnection()`（フォアグラウンド復帰時のみ）でしか行われない。バックグラウンド中に接続が「サイレントに」死んだ場合、原因1の問題に加えて、ゾンビ接続の検出も遅れる。

**修正**: 接続成功時に定期ヘルスチェックタイマーを開始する。30 秒ごとに `isConnected` をチェックし、false なら `_onDisconnected()` を呼ぶ（→ 即時再接続に繋がる）。

## Codex レビュー結果（反映済み）

Codex (gpt-5.3-codex) によるレビューで以下が指摘された:

1. **レース条件が最大リスク**: `_onDisconnected`、ヘルスチェック、サービス keepalive、アプリ復帰の4つが同時に `reconnect` を呼ぶ可能性がある → 既存の `_isCheckingConnection` フラグと `reconnect()` の status ガード（`reconnecting`/`connecting`/`connected` なら return）で排他制御されているが、全トリガーで一貫して守られていることを確認すること
2. **ヘルスチェックタイマーのライフサイクル**: `connected` 時に start、`disconnect`/`dispose` 時に cancel を徹底 → `_cleanupConnections()` で cancel、`_startHealthCheck()` は先に cancel してから再 start
3. **_onDisconnected の無限ループリスク**: reconnect 失敗 → `_onDisconnected` 再発火のループリスク → reconnect の retry は Timer ベースのバックオフなので即時再発火はしない。また `_onDisconnected` は `reconnecting` 状態なら return するので、reconnect 中の `client.done` は無視される
4. **全体評価**: A+B+C で「大幅に改善」される。Android OEM のバッテリー管理は完全には制御できないが、現実的に最善のアプローチ

## 実装手順

### 手順 1: _onDisconnected() で即時再接続を試みる

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

変更前:
```dart
void _onDisconnected() {
  // 再接続中なら無視（reconnect() が完了を処理する）
  if (state.status == ConnectionStatus.reconnecting) return;
  // 既に切断状態なら無視
  if (state.status == ConnectionStatus.disconnected) return;
  state = state.copyWith(
    status: ConnectionStatus.disconnected,
    errorMessage: 'Connection lost',
    clearChannelManager: true,
  );
}
```

変更後:
```dart
void _onDisconnected() {
  // 再接続中なら無視（reconnect() が完了を処理する）
  if (state.status == ConnectionStatus.reconnecting) return;
  // 既に切断状態なら無視
  if (state.status == ConnectionStatus.disconnected) return;
  state = state.copyWith(
    status: ConnectionStatus.disconnected,
    errorMessage: 'Connection lost',
    clearChannelManager: true,
  );
  // バックグラウンドでも即座に再接続を試みる
  // フォアグラウンドサービスが動いている限りプロセスは生きている
  if (_config != null) {
    reconnect();
  }
}
```

### 手順 2: 接続成功時に定期ヘルスチェックタイマーを開始

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

フィールド追加（`_retryTimer` の後に）:
```dart
Timer? _healthCheckTimer;
```

`connect()` の成功時と `reconnect()` の成功時にヘルスチェックタイマーを開始:

```dart
void _startHealthCheck() {
  _healthCheckTimer?.cancel();
  _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
    _periodicHealthCheck();
  });
}

void _periodicHealthCheck() {
  // 接続中でなければ何もしない
  if (state.status != ConnectionStatus.connected) return;
  // isConnected が false なら切断を検知
  if (_sshService == null || !_sshService!.isConnected) {
    _onDisconnected();
  }
}
```

`connect()` 内の接続成功時:
```dart
state = state.copyWith(
  status: ConnectionStatus.connected,
  terminal: terminal,
  channelManager: _channelManager,
);
_startHealthCheck();
```

`reconnect()` 内の接続成功時:
```dart
_retryCount = 0;
state = state.copyWith(
  status: ConnectionStatus.connected,
  terminal: terminal,
  channelManager: _channelManager,
);
_startHealthCheck();
```

`_cleanupConnections()` にタイマー停止を追加:
```dart
void _cleanupConnections() {
  _healthCheckTimer?.cancel();
  _healthCheckTimer = null;
  _flushTimer?.cancel();
  // ... 以下既存コード ...
}
```

### 手順 3: フォアグラウンドサービスに定期イベントを追加

ファイル: `lib/core/background/ssh_foreground_service.dart`

#### 3a. eventAction を repeat に変更

変更前:
```dart
foregroundTaskOptions: ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.nothing(),
  autoRunOnBoot: false,
  allowWakeLock: true,
  allowWifiLock: true,
),
```

変更後:
```dart
foregroundTaskOptions: ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.repeat(interval: 30000),
  autoRunOnBoot: false,
  allowWakeLock: true,
  allowWifiLock: true,
),
```

#### 3b. TaskHandler で定期的にメインイソレートにメッセージを送信

変更前:
```dart
class _NoOpTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
```

変更後:
```dart
class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    // メインイソレートに keepalive メッセージを送信
    // これによりメインイソレートのイベントループが活性化される
    FlutterForegroundTask.sendDataToMain('keepalive');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
```

`_serviceCallback` も更新:
```dart
@pragma('vm:entry-point')
void _serviceCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}
```

#### 3c. メインイソレート側でメッセージ受信を登録

ファイル: `lib/features/terminal/terminal_screen.dart`

`_TerminalScreenState` の `initState()` でサービスからのメッセージ受信を登録:

```dart
@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addObserver(this);
  // フォアグラウンドサービスからの keepalive メッセージを受信
  FlutterForegroundTask.addTaskDataCallback(_onTaskData);
}

@override
void dispose() {
  FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
  WidgetsBinding.instance.removeObserver(this);
  super.dispose();
}

void _onTaskData(Object data) {
  if (data == 'keepalive' && mounted) {
    // 全セッションのヘルスチェックを実行
    final managerState = ref.read(sessionManagerProvider);
    for (final session in managerState.sessions) {
      final notifier = ref.read(
        terminalConnectionProvider(session.sessionId).notifier,
      );
      notifier.checkConnection();
    }
  }
}
```

`import 'package:flutter_foreground_task/flutter_foreground_task.dart';` を追加する。

**注意**: `FlutterForegroundTask.addTaskDataCallback` は `Platform.isAndroid` のガードは不要（非 Android では callback が呼ばれないだけ）。

### 手順 4: リトライ回数を増やす

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

バックグラウンドでの自動再接続を考慮して、リトライ回数を 3 → 5 に増やし、最大バックオフも長くする:

変更前:
```dart
static const _maxRetries = 3;
```

変更後:
```dart
static const _maxRetries = 5;
```

これにより、リトライスケジュールは: 2s, 4s, 8s, 16s, 32s（合計約 62 秒間リトライし続ける）。

## テストへの影響

- `_onDisconnected()` で `reconnect()` を呼ぶようになるため、テストで `_onDisconnected()` 相当の状態遷移をテストしている箇所は期待値の更新が必要。
- `_healthCheckTimer` は `_cleanupConnections()` で停止されるため、テストの teardown で問題にならないはず。
- フォアグラウンドサービスの変更は `Platform.isAndroid` ガードにより Linux テスト環境では no-op。
- `FlutterForegroundTask.addTaskDataCallback` / `removeTaskDataCallback` はテスト環境で呼ばれても安全（イベントが来ないだけ）。

## 実装順序

1. `lib/features/terminal/terminal_connection_provider.dart`:
   - `_healthCheckTimer` フィールド追加
   - `_startHealthCheck()` / `_periodicHealthCheck()` メソッド追加
   - `_onDisconnected()` に `reconnect()` 呼び出し追加
   - `connect()` / `reconnect()` 成功時に `_startHealthCheck()` 呼び出し
   - `_cleanupConnections()` に `_healthCheckTimer` 停止追加
   - `_maxRetries` を 5 に変更
2. `lib/core/background/ssh_foreground_service.dart`:
   - `eventAction` を `repeat(interval: 30000)` に変更
   - `_NoOpTaskHandler` → `_KeepAliveTaskHandler` にリネーム
   - `onRepeatEvent` で `sendDataToMain('keepalive')` 送信
3. `lib/features/terminal/terminal_screen.dart`:
   - `FlutterForegroundTask` import 追加
   - `initState()` で `addTaskDataCallback` 登録
   - `dispose()` で `removeTaskDataCallback` 解除
   - `_onTaskData()` で全セッションの `checkConnection()` 実行
4. テスト確認・修正
5. `~/flutter/bin/flutter analyze`
6. `~/flutter/bin/flutter test`
7. `~/flutter/bin/flutter build apk --debug`
