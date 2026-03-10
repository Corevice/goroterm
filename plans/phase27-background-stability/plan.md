---
goal: "Phase 27 - バックグラウンド接続安定性の改善"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 27: バックグラウンド接続安定性の改善

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

---

## 問題 1: keepAlive() のタイムアウトバグ（致命的）

### 根本原因

ファイル: `lib/core/ssh/ssh_client_service.dart`

```dart
Future<bool> keepAlive() async {
  if (_client == null || _client!.isClosed) return false;
  try {
    final session = await _client!.execute('true');
    await session.done.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},  // ← バグ: void を返すだけでタイムアウトを正常終了扱いにする
    );
    return true;  // ← タイムアウトしても true が返る
  } catch (_) {
    return false;
  }
}
```

`session.done` は `Future<void>` を返す。`timeout()` の `onTimeout` コールバックも `void` を返すため、タイムアウト時に例外が発生せず、そのまま `return true` に到達する。

つまり、SSH 接続が実際にはハングしていても、`keepAlive()` は常に `true` を返す。`activeKeepAlive()` は接続が生きていると判断し、ゾンビ接続が検知されない。

### 修正方針

`onTimeout` を削除し、`TimeoutException` を `catch` して `false` を返す。

変更前:
```dart
Future<bool> keepAlive() async {
  if (_client == null || _client!.isClosed) return false;
  try {
    final session = await _client!.execute('true');
    await session.done.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    return true;
  } catch (_) {
    return false;
  }
}
```

変更後:
```dart
Future<bool> keepAlive() async {
  if (_client == null || _client!.isClosed) return false;
  try {
    final session = await _client!
        .execute('true')
        .timeout(const Duration(seconds: 5));
    await session.done.timeout(const Duration(seconds: 5));
    return true;
  } on TimeoutException {
    return false;
  } catch (_) {
    return false;
  }
}
```

`execute()` 自体もタイムアウトする可能性があるため、両方にタイムアウトを設定する。`TimeoutException` を明示的にキャッチすることで、タイムアウト時に `false` を返す。

---

## 問題 2: activeKeepAlive() が切断状態を放置する

### 根本原因

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

```dart
Future<void> activeKeepAlive() async {
  if (state.status != ConnectionStatus.connected) return;  // ← disconnected なら何もしない
  if (_sshService == null) return;
  final alive = await _sshService!.keepAlive();
  if (!alive) {
    _onDisconnected();
  }
}
```

フォアグラウンドサービスは 10 秒ごとに `keepalive` メッセージを送信し、メインイソレートで `activeKeepAlive()` が呼ばれる。しかし、接続が `disconnected` 状態の場合、`activeKeepAlive()` は即座に `return` する。

自動リトライ（`_maxRetries = 5`）が尽きた後、接続は `disconnected` のまま放置される。フォアグラウンドサービスは動き続けているのに、接続を回復しようとしない。

### 修正方針

`activeKeepAlive()` で `disconnected` 状態かつリトライ上限到達済みの場合、`reconnect()` を試みる。ただし、頻繁な再接続を防ぐため、最後の再接続試行から一定時間（60 秒）経過していることを条件とする。

変更前:
```dart
Future<void> activeKeepAlive() async {
  if (state.status != ConnectionStatus.connected) return;
  if (_sshService == null) return;
  final alive = await _sshService!.keepAlive();
  if (!alive) {
    _onDisconnected();
  }
}
```

変更後:
```dart
DateTime? _lastReconnectAttempt;
bool _isActiveKeepAliveRunning = false;

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
    if (_sshService == null) return;
    final alive = await _sshService!.keepAlive();
    if (!alive) {
      _onDisconnected();
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
        now.difference(_lastReconnectAttempt!) < const Duration(seconds: 60)) {
      return; // 前回の再接続試行から 60 秒未満なら待つ
    }
    _lastReconnectAttempt = now;
    _retryCount = 0; // カウンタをリセットして再接続を許可
    await reconnect();
  }
}
```

さらに、`reconnect()` の成功時に `_lastReconnectAttempt` をリセットする:

`reconnect()` の成功ブロックに追加:
```dart
_lastReconnectAttempt = null;
```

**Codex レビュー指摘対応**:
- `_isActiveKeepAliveRunning` ガードを追加: `activeKeepAlive()` は `terminal_screen.dart:69` から unawaited で呼ばれるため、前回の呼び出しが完了する前に次の呼び出しが発生する可能性がある
- リトライ尽き判定: `_retryTimer == null && _retryCount >= _maxRetries` の条件を追加し、自動リトライのバックオフ中は干渉しない
- `_lastReconnectAttempt` の更新は実際に `reconnect()` を呼ぶ直前にのみ行う（早期 return パスでは更新しない）

---

## 問題 3: フォアグラウンドサービス再起動時の初回 keepalive 遅延

### 根本原因

ファイル: `lib/core/background/ssh_foreground_service.dart`

```dart
class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  // ...
}
```

`onStart` が空のため、サービス再起動後の最初の keepalive が `onRepeatEvent` の間隔（10 秒）まで遅延する。OS がサービスを再起動した直後は接続が切れている可能性が高いため、即座に keepalive を送信すべき。

### 修正方針

`onStart` で即座に keepalive メッセージを送信する。

変更前:
```dart
@override
Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
```

変更後:
```dart
@override
Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
  // サービス起動/再起動直後に即座に keepalive を送信
  FlutterForegroundTask.sendDataToMain('keepalive');
}
```

---

## 問題 4: バッテリー最適化拒否時のユーザーフィードバック不足

### 根本原因

ファイル: `lib/core/background/ssh_foreground_service.dart`

```dart
if (!_batteryOptimizationRequested) {
  _batteryOptimizationRequested = true;
  final isIgnoring =
      await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  if (!isIgnoring) {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}
```

ユーザーがバッテリー最適化の無効化を拒否しても、フラグ（`_batteryOptimizationRequested`）が `true` のままなので再度要求されない。また、拒否した結果としてバックグラウンドで接続が切れやすくなることがユーザーに伝わらない。

### 修正方針

`ensureRunning()` の戻り値に「バッテリー最適化が無効化されているか」を含め、呼び出し元で SnackBar を表示する。

#### 4a. `SshForegroundService` に状態確認メソッドを追加

```dart
/// バッテリー最適化が無効化されているか確認する。
/// 無効化されていなければ false を返す（接続が切れやすい状態）。
static Future<bool> isBatteryOptimizationDisabled() async {
  if (!Platform.isAndroid) return true;
  return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
}
```

#### 4b. `ensureRunning()` の戻り値を変更

変更前:
```dart
static Future<void> ensureRunning({required int sessionCount}) async {
```

変更後:
```dart
/// サービスを起動/更新する。
/// 戻り値: バッテリー最適化が無効化されていない場合 false。
static Future<bool> ensureRunning({required int sessionCount}) async {
```

バッテリー最適化要求後の結果を確認:

```dart
if (!_batteryOptimizationRequested) {
  _batteryOptimizationRequested = true;
  final isIgnoring =
      await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  if (!isIgnoring) {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}

// ... サービス起動/更新 ...

// バッテリー最適化の状態を返す
final batteryOk =
    await FlutterForegroundTask.isIgnoringBatteryOptimizations;
return batteryOk;
```

#### 4c. 呼び出し元でフィードバック表示（Codex レビュー指摘: provider 経由に変更）

**Codex レビュー指摘**: `ensureRunning()` の呼び出し元は `session_manager.dart`（Notifier 層）であり、`BuildContext` にアクセスできない。SnackBar を直接表示できないため、`SessionManagerState` に警告フラグを追加し、UI 層で `ref.listen` して SnackBar を表示する。

##### ファイル: `lib/features/terminal/session_manager.dart`

`SessionManagerState` に `batteryWarning` フラグを追加:

```dart
class SessionManagerState {
  // ... 既存フィールド ...
  final bool batteryWarning;

  const SessionManagerState({
    // ... 既存パラメータ ...
    this.batteryWarning = false,
  });

  SessionManagerState copyWith({
    // ... 既存パラメータ ...
    bool? batteryWarning,
  }) {
    return SessionManagerState(
      // ...
      batteryWarning: batteryWarning ?? this.batteryWarning,
    );
  }
}
```

既存の `SshForegroundService.ensureRunning()` 呼び出し（3箇所、現在 unawaited）を変更:

変更前:
```dart
SshForegroundService.ensureRunning(sessionCount: updated.length);
```

変更後:
```dart
SshForegroundService.ensureRunning(sessionCount: updated.length).then((batteryOk) {
  if (!batteryOk) {
    state = state.copyWith(batteryWarning: true);
  }
});
```

##### ファイル: `lib/features/terminal/terminal_screen.dart`

`build()` 内で `ref.listen` を追加:

```dart
ref.listen<SessionManagerState>(sessionManagerProvider, (prev, next) {
  if (next.batteryWarning && !(prev?.batteryWarning ?? false)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'バッテリー最適化が有効です。バックグラウンドでSSH接続が切れる可能性があります。',
        ),
        duration: Duration(seconds: 5),
      ),
    );
  }
});
```

`ensureRunning()` は初回のみ `false` を返す（`_batteryOptimizationRequested` フラグで制御）ため、SnackBar は最初の接続時に 1 回だけ表示される。

完全版の `ensureRunning()`:

```dart
static Future<bool> ensureRunning({required int sessionCount}) async {
  if (!Platform.isAndroid) return true;
  if (!_initialized) return true;

  // ... notification permission ...

  bool batteryWarningNeeded = false;
  if (!_batteryOptimizationRequested) {
    _batteryOptimizationRequested = true;
    final isIgnoring =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!isIgnoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      // 要求後に再確認
      final isIgnoringNow =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      batteryWarningNeeded = !isIgnoringNow;
    }
  }

  // ... start/update service ...

  return !batteryWarningNeeded; // true = OK, false = warning needed
}
```

---

## 実装手順

### 手順 1: keepAlive() のタイムアウトバグ修正

ファイル: `lib/core/ssh/ssh_client_service.dart`

`import 'dart:async';` が既にインポートされていることを確認（`TimeoutException` に必要）。

変更前:
```dart
Future<bool> keepAlive() async {
  if (_client == null || _client!.isClosed) return false;
  try {
    final session = await _client!.execute('true');
    await session.done.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    return true;
  } catch (_) {
    return false;
  }
}
```

変更後:
```dart
Future<bool> keepAlive() async {
  if (_client == null || _client!.isClosed) return false;
  try {
    final session = await _client!
        .execute('true')
        .timeout(const Duration(seconds: 5));
    await session.done.timeout(const Duration(seconds: 5));
    return true;
  } on TimeoutException {
    return false;
  } catch (_) {
    return false;
  }
}
```

### 手順 2: activeKeepAlive() の切断状態リカバリ

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

#### 2a. 状態変数を追加

既存の `_retryTimer` 等の宣言の近くに追加:
```dart
DateTime? _lastReconnectAttempt;
bool _isActiveKeepAliveRunning = false;
```

#### 2b. activeKeepAlive() を変更

変更前:
```dart
Future<void> activeKeepAlive() async {
  if (state.status != ConnectionStatus.connected) return;
  if (_sshService == null) return;
  final alive = await _sshService!.keepAlive();
  if (!alive) {
    _onDisconnected();
  }
}
```

変更後:
```dart
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
    if (_sshService == null) return;
    final alive = await _sshService!.keepAlive();
    if (!alive) {
      _onDisconnected();
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
        now.difference(_lastReconnectAttempt!) < const Duration(seconds: 60)) {
      return;
    }
    _lastReconnectAttempt = now;
    _retryCount = 0;
    await reconnect();
  }
}
```

#### 2c. reconnect() 成功時に _lastReconnectAttempt をリセット

`reconnect()` メソッド内の成功ブロック（`_retryCount = 0;` の行の近く）に追加:

```dart
_retryCount = 0;
_lastReconnectAttempt = null;  // ← 追加
```

### 手順 3: フォアグラウンドサービスの onStart 修正

ファイル: `lib/core/background/ssh_foreground_service.dart`

変更前:
```dart
@override
Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
```

変更後:
```dart
@override
Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
  // サービス起動/再起動直後に即座に keepalive を送信
  FlutterForegroundTask.sendDataToMain('keepalive');
}
```

### 手順 4: バッテリー最適化フィードバック

#### 4a. ensureRunning() の戻り値を変更

ファイル: `lib/core/background/ssh_foreground_service.dart`

変更前:
```dart
static Future<void> ensureRunning({required int sessionCount}) async {
  if (!Platform.isAndroid) return;
  if (!_initialized) return;
```

変更後:
```dart
/// サービスを起動/更新する。
/// 戻り値: false ならバッテリー最適化が有効でバックグラウンド接続が不安定になる可能性がある。
static Future<bool> ensureRunning({required int sessionCount}) async {
  if (!Platform.isAndroid) return true;
  if (!_initialized) return true;
```

バッテリー最適化要求部分を変更:

変更前:
```dart
  if (!_batteryOptimizationRequested) {
    _batteryOptimizationRequested = true;
    final isIgnoring =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!isIgnoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }
```

変更後:
```dart
  bool batteryWarningNeeded = false;
  if (!_batteryOptimizationRequested) {
    _batteryOptimizationRequested = true;
    final isIgnoring =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!isIgnoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      // 要求後に再確認
      final isIgnoringNow =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      batteryWarningNeeded = !isIgnoringNow;
    }
  }
```

メソッド末尾の `return` を変更（既存の `}` の前）:

変更前（暗黙の `return;`）:
```dart
  }
}
```

変更後:
```dart
  }
  return !batteryWarningNeeded;
}
```

#### 4b. SessionManagerState に batteryWarning フラグ追加

ファイル: `lib/features/terminal/session_manager.dart`

`SessionManagerState` に `batteryWarning` フィールドを追加（初期値 `false`）し、`copyWith()` にも追加する。

既存の `SshForegroundService.ensureRunning()` 呼び出し（3箇所、現在 unawaited）を変更:

変更前:
```dart
SshForegroundService.ensureRunning(sessionCount: updated.length);
```

変更後:
```dart
SshForegroundService.ensureRunning(sessionCount: updated.length).then((batteryOk) {
  if (!batteryOk) {
    state = state.copyWith(batteryWarning: true);
  }
});
```

#### 4c. UI 層で ref.listen して SnackBar 表示

ファイル: `lib/features/terminal/terminal_screen.dart`

`build()` 内で `ref.listen` を追加:

```dart
ref.listen<SessionManagerState>(sessionManagerProvider, (prev, next) {
  if (next.batteryWarning && !(prev?.batteryWarning ?? false)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'バッテリー最適化が有効です。バックグラウンドでSSH接続が切れる可能性があります。',
        ),
        duration: Duration(seconds: 5),
      ),
    );
  }
});
```

---

## テストへの影響

- `ssh_client_service_test.dart`: `keepAlive()` のテストがある場合、タイムアウト時の振る舞いが変わる（`true` → `false`）。テスト更新が必要
- `terminal_connection_provider_test.dart`: `activeKeepAlive()` が `disconnected` 状態で `reconnect()` を呼ぶようになる。モックの期待値更新が必要。`_isActiveKeepAliveRunning` ガードのテスト追加を推奨
- `ssh_foreground_service.dart`: `ensureRunning()` の戻り値が `void` → `bool` に変更。呼び出し元のテスト更新が必要
- `session_manager_test.dart`: `SessionManagerState` に `batteryWarning` フィールド追加。`copyWith()` のテスト更新が必要
- `_lastReconnectAttempt` は `DateTime.now()` に依存するため、テストで時間制御が必要な場合は `Clock` の注入を検討（ただし今回は不要）

## 実装順序

1. `lib/core/ssh/ssh_client_service.dart`:
   - `keepAlive()` のタイムアウトバグ修正
2. `lib/features/terminal/terminal_connection_provider.dart`:
   - `_lastReconnectAttempt` / `_isActiveKeepAliveRunning` 変数追加
   - `activeKeepAlive()` を重複実行ガード付きに変更、`_activeKeepAliveCore()` 分離
   - disconnected 状態のリカバリ（`_retryTimer == null && _retryCount >= _maxRetries` 条件付き）
   - `reconnect()` 成功時の `_lastReconnectAttempt` リセット
3. `lib/core/background/ssh_foreground_service.dart`:
   - `onStart` に即座 keepalive 送信追加
   - `ensureRunning()` の戻り値を `bool` に変更
   - バッテリー最適化拒否時のフラグ管理
4. `lib/features/terminal/session_manager.dart`:
   - `SessionManagerState` に `batteryWarning` フィールド追加
   - `ensureRunning()` 呼び出し（3箇所）を `.then()` で戻り値処理
5. `lib/features/terminal/terminal_screen.dart`:
   - `ref.listen` で `batteryWarning` フラグを監視し SnackBar 表示
6. テスト確認・修正
7. `~/flutter/bin/flutter analyze`
8. `~/flutter/bin/flutter test`
9. `~/flutter/bin/flutter build apk --debug`
