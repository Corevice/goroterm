---
goal: "Phase 13 - Android Foreground Service でバックグラウンド接続維持"
verifyCommands:
  - ~/flutter/bin/flutter analyze
  - ~/flutter/bin/flutter test
  - ~/flutter/bin/flutter build apk --debug
maxAttempts: 5
executeModel: claude-sonnet-4-6
evaluateModel: claude-sonnet-4-6
---

# Phase 13: Android Foreground Service でバックグラウンド SSH 接続維持

全体の実装計画は `plans/terminal-ssh-app/implementation-plan.md` を参照すること。
Flutter SDK は `~/flutter/bin/flutter` にある（PATH に含まれていないため、フルパスで実行すること）。

## 背景

現状、アプリがバックグラウンドに行くと Android OS が TCP ソケットを切断し、SSH 接続が切れる。Android Foreground Service を使用してプロセスを維持し、WiFi ロックで通信を保護することで、バックグラウンドでも SSH 接続を維持する。

## 技術選定

**`flutter_foreground_task`** パッケージを使用する。

理由:
- SSH 接続はメインアイソレートの Riverpod プロバイダで管理されている。フォアグラウンドサービスは「このプロセスを維持してほしい」と Android に伝える役割のみ
- SSH をサービスアイソレートに移動する必要がない（`flutter_background_service` と異なり）
- Android 14+ の `foregroundServiceType` サポートが組み込み
- WiFi ロック (`allowWifiLock`) をサポート — 画面オフ時も WiFi を維持

## 実装手順

### 手順 1: pubspec.yaml に依存追加

```yaml
dependencies:
  flutter_foreground_task: ^8.14.0
```

追加後 `~/flutter/bin/flutter pub get` を実行。

### 手順 2: AndroidManifest.xml にパーミッションとサービス宣言を追加

ファイル: `android/app/src/main/AndroidManifest.xml`

`<manifest>` 直下（`<application>` の前）に以下のパーミッションを追加:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

`<application>` タグ内（`<activity>` と同じレベル）にサービス宣言を追加:

```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundTaskService"
    android:exported="false"
    android:foregroundServiceType="dataSync" />
```

**重要**: `android:foregroundServiceType="dataSync"` は `targetSdk = 34`（Android 14）で必須。省略すると `MissingForegroundServiceTypeException` でクラッシュする。

### 手順 3: SshForegroundService ラッパークラスを作成

新規ファイル: `lib/core/background/ssh_foreground_service.dart`

```dart
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android Foreground Service ラッパー。
/// SSH 接続中にプロセスと WiFi を維持する。
class SshForegroundService {
  static bool _initialized = false;
  static bool _running = false;

  /// アプリ起動時に一度だけ呼ぶ。
  static void init() {
    if (!Platform.isAndroid) return;
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ssh_connection',
        channelName: 'SSH Connection',
        channelDescription: 'Keeps SSH connections alive in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWifiLock: true,
      ),
    );
  }

  /// SSH セッションが開始されたときに呼ぶ。
  /// サービスが未起動なら起動し、起動済みなら通知を更新する。
  static Future<void> ensureRunning({required int sessionCount}) async {
    if (!Platform.isAndroid) return;
    if (!_initialized) return;

    // Android 13+ で通知パーミッションを要求
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    final title = 'SSH Connected';
    final text = '$sessionCount session${sessionCount == 1 ? '' : 's'} active';

    if (!_running) {
      await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text,
        callback: _serviceCallback,
      );
      _running = true;
    } else {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    }
  }

  /// 全 SSH セッションが閉じられたときに呼ぶ。
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_running) return;
    await FlutterForegroundTask.stopService();
    _running = false;
  }
}

// flutter_foreground_task が要求するトップレベルコールバック。
// SSH 接続はメインアイソレートで動作するため、ここでは何もしない。
@pragma('vm:entry-point')
void _serviceCallback() {
  FlutterForegroundTask.setTaskHandler(_NoOpTaskHandler());
}

class _NoOpTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
```

### 手順 4: main.dart で初期化

ファイル: `lib/main.dart`

`WidgetsFlutterBinding.ensureInitialized()` の後、`runApp()` の前に追加:

```dart
import 'core/background/ssh_foreground_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SshForegroundService.init(); // ← 追加
  // ... 既存のDB初期化等
  runApp(...);
}
```

### 手順 5: SessionManagerNotifier でサービスライフサイクルを管理

ファイル: `lib/features/terminal/session_manager.dart`

`addSession()` と `removeSession()` でフォアグラウンドサービスの開始/更新/停止を行う。

```dart
import '../../core/background/ssh_foreground_service.dart';

class SessionManagerNotifier extends Notifier<SessionManagerState> {
  // ... 既存コード

  String addSession({required int connectionId, required String label}) {
    _sessionCounter++;
    final sessionId = 'session_${connectionId}_$_sessionCounter';
    final session = TerminalSession(
      sessionId: sessionId,
      connectionId: connectionId,
      label: label,
    );
    final updated = [...state.sessions, session];
    state = state.copyWith(sessions: updated, activeSessionId: sessionId);

    // フォアグラウンドサービスを開始/更新
    SshForegroundService.ensureRunning(sessionCount: updated.length);

    return sessionId;
  }

  void removeSession(String sessionId) {
    final updated =
        state.sessions.where((s) => s.sessionId != sessionId).toList();
    ref.invalidate(terminalConnectionProvider(sessionId));

    String? newActive = state.activeSessionId;
    if (newActive == sessionId) {
      newActive = updated.isNotEmpty ? updated.last.sessionId : null;
    }
    state = SessionManagerState(sessions: updated, activeSessionId: newActive);

    // 全セッション終了時にサービスを停止、それ以外は通知更新
    if (updated.isEmpty) {
      SshForegroundService.stop();
    } else {
      SshForegroundService.ensureRunning(sessionCount: updated.length);
    }
  }

  // ... 既存コード
}
```

### 手順 6: TerminalScreen の WidgetsBindingObserver を調整

ファイル: `lib/features/terminal/terminal_screen.dart`

フォアグラウンドサービスがプロセスを維持するため、`didChangeAppLifecycleState` の `checkConnection()` 呼び出しを短い遅延で行う（念のための安全チェック）。

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    // フォアグラウンドサービスのおかげで通常は接続維持されているが、
    // 万一の切断に備えて短い遅延後にチェック
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      final managerState = ref.read(sessionManagerProvider);
      final activeId = managerState.activeSessionId;
      if (activeId != null) {
        ref
            .read(terminalConnectionProvider(activeId).notifier)
            .checkConnection();
      }
    });
  }
}
```

## Android 14+ 注意事項

- `targetSdk = 34` のため `foregroundServiceType="dataSync"` は必須
- `FOREGROUND_SERVICE_DATA_SYNC` パーミッションも必須（なければ `SecurityException`）
- Android 13+ (API 33) では `POST_NOTIFICATIONS` のランタイムパーミッション要求が必要（`SshForegroundService.ensureRunning()` 内で処理）
- Android 15 (API 35) では `dataSync` タイプのフォアグラウンドサービスに6時間/24時間の制限がある。`targetSdk = 34` の現状では問題なし

## テストについて

`SshForegroundService` は `Platform.isAndroid` ガードがあるため、テスト環境（Linux）では全メソッドが即座に return する。既存テストへの影響なし。

`SessionManagerNotifier` のテストでは `SshForegroundService` の呼び出しは副作用として無視される（Android 以外のプラットフォームでは no-op）。

## 実装順序

1. `pubspec.yaml` に `flutter_foreground_task: ^8.14.0` を追加し `flutter pub get`
2. `android/app/src/main/AndroidManifest.xml` にパーミッションとサービス宣言を追加
3. `lib/core/background/ssh_foreground_service.dart` を新規作成
4. `lib/main.dart` で `SshForegroundService.init()` を呼ぶ
5. `lib/features/terminal/session_manager.dart` の `addSession` / `removeSession` にサービス管理を追加
6. `lib/features/terminal/terminal_screen.dart` の `didChangeAppLifecycleState` の遅延を 2 秒に変更（既に1秒の場合）
7. `flutter analyze` でエラーがないことを確認
8. `flutter test` で全テストパスを確認
9. `flutter build apk --debug` でビルド
