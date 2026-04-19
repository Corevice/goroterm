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
import 'core/preferences/power_settings.dart';
import 'core/storage/database.dart';
import 'features/connections/connection_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      child: const TerminalSshApp(),
    ),
  );
}
