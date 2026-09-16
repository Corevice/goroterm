import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_ssh_app/features/terminal/terminal_connection_provider.dart';

@Timeout(Duration(seconds: 30))
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // resume / 生存確認タイマーの jitter を全テスト共通で無効化する。
  // 既存テストは fakeAsync で正確な経過時間を検証しているため、乱数の
  // 遅延が入るとタイミングがずれて壊れる。
  TerminalConnectionNotifier.jitterProvider = (Duration max) => Duration.zero;
  await testMain();
}
