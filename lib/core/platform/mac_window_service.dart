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

  /// セッションウィンドウのネイティブタブに Claude Code 稼働インジケータ
  /// (スピナー) を出す/消す。各セッションウィンドウの Dart が自分の
  /// claudeRunning を監視して呼ぶ。
  static Future<void> setTabRunning({
    required int connectionId,
    required String tmuxSessionName,
    required bool running,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setTabRunning', {
        'connectionId': connectionId,
        'tmuxSessionName': tmuxSessionName,
        'running': running,
      });
    } catch (e) {
      AppLogger.instance.log('[multi-window] setTabRunning failed: $e');
    }
  }

  /// 現在のウィンドウが属する OS ネイティブタブグループで、隣のタブへ移動する。
  /// [next] が true なら次のタブ、false なら前のタブ。
  ///
  /// アプリ内タブを廃した macOS では、ターミナルの左右スワイプをこの
  /// ネイティブタブ切り替えに繋ぐことでタブ間移動を復活させる。
  static Future<void> selectAdjacentTab({required bool next}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(
        next ? 'selectNextTab' : 'selectPreviousTab',
      );
    } catch (e) {
      AppLogger.instance.log('[multi-window] selectAdjacentTab failed: $e');
    }
  }

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
