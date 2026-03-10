---
goal: "Phase 15 - バックグラウンド接続維持の根本修正"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 15: バックグラウンド接続維持の根本修正

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

Phase 13 でフォアグラウンドサービスを実装し、Phase 14 で probe 機能を追加したが、バックグラウンドから復帰すると接続が切れている問題が解消していない。ターミナルに入力しても反応がなく、ファイルブラウザも操作不可になる。

## 根本原因分析

### 原因 1: auto-reconnect のステートマシンバグ（致命的）

`checkConnection()` と `reconnect()` のステート遷移にバグがあり、**どちらのケースでも自動再接続が発動しない**：

**ケース A: ゾンビ接続（dartssh2 が切断を検知していない）**
1. バックグラウンドで TCP ソケットが死ぬが、dartssh2 の `isClosed` は false のまま
2. 復帰時 `checkConnection()` → `isConnected == true` → `probe()` 実行 → タイムアウト/失敗
3. `reconnect()` を呼ぶが、state は `ConnectionStatus.connected` のまま
4. **`reconnect()` 内の `state.status == ConnectionStatus.connected` ガードに引っかかって即 return** → 再接続されない

**ケース B: 検知済み切断（dartssh2 が切断を検知した場合）**
1. バックグラウンド中に keepalive 失敗 → `client.done` 発火 → `_onDisconnected()` → state が `disconnected` に
2. 復帰時 `checkConnection()` → **`state.status == ConnectionStatus.disconnected` で早期 return** → 再接続されない
3. バナーは表示されるが、ユーザーが手動で Reconnect ボタンを押さないと復帰しない

### 原因 2: checkConnection() のレース条件

`didChangeAppLifecycleState` が全セッションに対して `checkConnection()` を await せずに並行実行するため、同じセッションで `checkConnection()` が複数回並行実行される可能性がある。

### 原因 3: バッテリー最適化による制限

Android のバッテリー最適化が有効だと、フォアグラウンドサービスがあっても OS がネットワーク接続を制限する場合がある。特に Samsung、Xiaomi、OPPO 等の OEM カスタム ROM で顕著。

### 原因 4: SSH keepalive の間隔

dartssh2 の keepalive は 15 秒間隔だが、バッテリー最適化で keepalive パケットの送信が遅延すると、NAT エントリが期限切れになる可能性がある。

## 修正方針

**方針**: バックグラウンドでの接続切断を完全に防ぐことは Android の制約上難しい。以下の二段構えで対応する：

1. **切断防止を最大限強化**: バッテリー最適化の無効化を要求、keepalive 間隔の短縮
2. **切断時の自動復帰を確実に動作させる**: checkConnection / reconnect のステートマシンバグを修正し、フォアグラウンド復帰時に全セッションをシームレスに再接続

## 実装手順

### 手順 1: checkConnection() のステートマシンバグを修正 + レース条件ガード追加

ファイル: `lib/features/terminal/terminal_connection_provider.dart`

`_isCheckingConnection` フラグを追加し、`checkConnection()` のロジックを修正する。

フィールド追加（`_passphrase` の後に）:
```dart
  bool _isCheckingConnection = false;
```

現在の `checkConnection()` を以下に**完全に置き換える**:

```dart
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

      // ケース A: state が connected だが実際は死んでいる（ゾンビ）可能性
      if (_sshService != null && _sshService!.isConnected) {
        try {
          final probeOk = await _sshService!.probe().timeout(
            const Duration(seconds: 5),
            onTimeout: () => false,
          );
          if (probeOk) return; // 本当に生きている
        } catch (_) {
          // プローブ失敗 = 接続は死んでいる
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
```

**変更ポイント**:
- `_isCheckingConnection` フラグでレース条件を防止
- `disconnected` 状態での早期リターンを削除 → 代わりに `reconnect()` を呼ぶ
- probe 失敗後、state を `disconnected` に変更してから `reconnect()` を呼ぶ（`reconnect()` は `connected` 状態では何もしないため）
- `_config == null` の場合は `_onDisconnected()` を呼ばず単に return（一度も接続していないセッションなので）
- `try/finally` で `_isCheckingConnection` を確実にリセット

### 手順 2: バッテリー最適化の無効化を要求

ファイル: `lib/core/background/ssh_foreground_service.dart`

`ensureRunning()` 内でバッテリー最適化の無効化をリクエストする。初回のみ要求。

`_running` フィールドの後に追加:
```dart
  static bool _batteryOptimizationRequested = false;
```

`ensureRunning()` の通知パーミッション要求の後、サービス起動の前に以下を追加:

```dart
    // バッテリー最適化の無効化を要求（初回のみ）
    if (!_batteryOptimizationRequested) {
      _batteryOptimizationRequested = true;
      final isIgnoring =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!isIgnoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
```

**注意**: `requestIgnoreBatteryOptimization()` は Android のシステムダイアログを表示する。ユーザーが許可すると、OS によるバックグラウンド制限が緩和される。`_batteryOptimizationRequested` はインメモリフラグなのでプロセス再起動後に再要求される可能性があるが、既に許可されていれば `isIgnoring` が true になるためダイアログは表示されない。

### 手順 3: AndroidManifest.xml にバッテリー最適化パーミッションを追加

ファイル: `android/app/src/main/AndroidManifest.xml`

`<manifest>` 直下（`<application>` の前）に以下を追加:

```xml
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
```

既存のパーミッション群（`POST_NOTIFICATIONS` の後）に追加すること。

### 手順 4: SSH keepalive 間隔を短縮

ファイル: `lib/core/ssh/ssh_client_service.dart`

`keepAliveInterval` を 15 秒から 10 秒に短縮し、NAT タイムアウトへの耐性を高める。

変更前:
```dart
keepAliveInterval: const Duration(seconds: 15),
```

変更後:
```dart
keepAliveInterval: const Duration(seconds: 10),
```

### 手順 5: 復帰時の checkConnection の遅延を短縮

ファイル: `lib/features/terminal/terminal_screen.dart`

`didChangeAppLifecycleState` の遅延を 1 秒から 500ms に短縮して、ユーザーが操作する前に再接続を開始する。

変更前:
```dart
Future.delayed(const Duration(seconds: 1), () {
```

変更後:
```dart
Future.delayed(const Duration(milliseconds: 500), () {
```

## テストへの影響

- `checkConnection()` のロジック変更はユニットテストに影響する可能性がある。`disconnected` 状態で `checkConnection()` を呼ぶと `reconnect()` が呼ばれるようになるため、テストの期待値を更新する必要がある場合がある。既存テストを確認し、`checkConnection()` の動作変更に合わせて修正すること。
- `_isCheckingConnection` フラグの追加はテストに影響しないはず（既存テストは単一呼び出し）。
- `SshForegroundService` の変更は `Platform.isAndroid` ガードにより Linux テスト環境では no-op。
- `keepAliveInterval` の変更はテストに影響なし。

## 実装順序

1. `lib/features/terminal/terminal_connection_provider.dart` — `_isCheckingConnection` フィールド追加 + `checkConnection()` のステートマシン修正
2. `android/app/src/main/AndroidManifest.xml` — `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` パーミッション追加
3. `lib/core/background/ssh_foreground_service.dart` — `_batteryOptimizationRequested` フィールド追加 + バッテリー最適化の無効化要求
4. `lib/core/ssh/ssh_client_service.dart` — keepalive 間隔を 10 秒に短縮
5. `lib/features/terminal/terminal_screen.dart` — 復帰時チェック遅延を 500ms に短縮
6. `~/flutter/bin/flutter analyze` でエラーがないことを確認
7. `~/flutter/bin/flutter test` で全テストパスを確認
8. `~/flutter/bin/flutter build apk --debug` でビルド
