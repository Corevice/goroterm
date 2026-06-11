import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// macOS のネイティブマルチウィンドウ（タブ分離）への橋渡し。
///
/// ネイティブ側の実装は macos/Runner/MainFlutterWindow.swift の
/// DetachedWindowManager。第二 Flutter エンジン + NSWindow を生成し、
/// 起動引数で対象セッションを伝える。
class MacWindowService {
  static const MethodChannel _channel =
      MethodChannel('com.example.terminalSshApp/multi_window');

  /// タブ分離をサポートするプラットフォームかどうか。
  static bool get isSupported => !kIsWeb && Platform.isMacOS;

  /// 指定 tmux セッションを表示する新しいウィンドウを開く。
  /// 成功したら true。非対応環境・ネイティブ側エラー時は false。
  static Future<bool> openSessionWindow({
    required int connectionId,
    required String tmuxSessionName,
    required String label,
  }) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openSessionWindow', {
        'connectionId': connectionId,
        'tmuxSessionName': tmuxSessionName,
        'label': label,
      });
      return ok ?? false;
    } catch (e) {
      AppLogger.instance.log('[multi-window] openSessionWindow failed: $e');
      return false;
    }
  }
}
