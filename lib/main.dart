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
import 'core/storage/database.dart';
import 'features/connections/connection_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  SshForegroundService.init();
  await NotificationService.instance.init();

  final dbFolder = await getApplicationDocumentsDirectory();
  final file = File(p.join(dbFolder.path, 'terminal_ssh.db'));
  final db = AppDatabase(NativeDatabase(file));

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
      child: const TerminalSshApp(),
    ),
  );
}
