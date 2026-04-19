import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../preferences/power_settings.dart';

/// Android Foreground Service ラッパー。
/// SSH 接続中にプロセスと WiFi を維持する。
class SshForegroundService {
  static bool _initialized = false;
  static bool _running = false;
  static bool _batteryOptimizationRequested = false;

  /// アプリ起動時に一度だけ呼ぶ。
  static void init() {
    if (!Platform.isAndroid) return;
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ssh_connection_v2',
        channelName: 'SSH Connection',
        channelDescription: 'Keeps SSH connections alive in the background',
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction:
            ForegroundTaskEventAction.repeat(PowerSettings.tickSeconds * 1000),
        autoRunOnBoot: false,
        allowWakeLock: false,
        allowWifiLock: false,
      ),
    );
  }

  /// SSH セッションが開始されたときに呼ぶ。
  /// サービスが未起動なら起動し、起動済みなら通知を更新する。
  /// 戻り値: false ならバッテリー最適化が有効でバックグラウンド接続が不安定になる可能性がある。
  static Future<bool> ensureRunning({required int sessionCount}) async {
    if (!Platform.isAndroid) return true;
    if (!_initialized) return true;

    // Android 13+ で通知パーミッションを要求
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    // バッテリー最適化の無効化を要求（初回のみ）
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

    final title = 'SSH Connected';
    final text = '$sessionCount session${sessionCount == 1 ? '' : 's'} active';

    if (!_running) {
      debugPrint('[SSH] Starting foreground service');
      await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text,
        callback: _serviceCallback,
      );
      _running = true;
      debugPrint('[SSH] Foreground service started');
    } else {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    }

    return !batteryWarningNeeded;
  }

  /// 全 SSH セッションが閉じられたときに呼ぶ。
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_running) return;
    debugPrint('[SSH] Stopping foreground service');
    await FlutterForegroundTask.stopService();
    _running = false;
  }
}

// flutter_foreground_task が要求するトップレベルコールバック。
// SSH 接続はメインアイソレートで動作するため、keepalive メッセージを送信するだけ。
@pragma('vm:entry-point')
void _serviceCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

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
    // 2回（120秒）に1回だけログ出力（頻繁すぎるとログが溢れる）
    if (_tickCount % 2 == 0) {
      debugPrint('[SSH][service] onRepeatEvent tick #$_tickCount');
    }
    FlutterForegroundTask.sendDataToMain('keepalive');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[SSH][service] TaskHandler onDestroy');
  }
}
