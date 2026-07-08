import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import 'app.dart';
import 'core/background/ssh_foreground_service.dart';
import 'core/notification/notification_service.dart';
import 'core/platform/detached_session_args.dart';
import 'core/preferences/power_settings.dart';
import 'core/storage/database.dart';
import 'core/update/desktop_updater.dart';
import 'features/connections/connection_provider.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // macOS のタブ分離ウィンドウ: ネイティブ側が第二エンジンの起動引数で
  // 対象セッションを渡してくる。通常起動では null。
  final detachedSession = DetachedSessionArgs.tryParse(args);

  // ユーザー設定（tick / TCP keepalive 間隔）を foreground service init より前に読む
  await PowerSettings.init();

  try {
    if (Platform.isAndroid) {
      FlutterForegroundTask.initCommunicationPort();
    }
    SshForegroundService.init();
  } catch (_) {}

  try {
    await NotificationService.instance.init();
  } catch (_) {}

  // デスクトップ自動アップデート。タブ分離ウィンドウ(detachedSession != null)は
  // メインウィンドウと重複して更新ダイアログが出ないよう、メインのみで起動する。
  if (detachedSession == null && DesktopUpdater.isSupported) {
    // 起動をブロックしないよう await しない。
    DesktopUpdater.init();
  }

  late AppDatabase db;
  try {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'terminal_ssh.db'));
    db = AppDatabase(NativeDatabase(file));
  } catch (e) {
    // DB 初期化失敗時はインメモリDB
    db = AppDatabase(NativeDatabase.memory());
  }

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
      child: TerminalSshApp(detachedSession: detachedSession),
    ),
  );
}
