import 'dart:io';

import 'package:auto_updater/auto_updater.dart';

/// デスクトップ(macOS / Windows)の自動アップデート。
///
/// macOS は Sparkle、Windows は WinSparkle を `auto_updater` プラグイン経由で
/// 利用する。更新情報(appcast)は GitHub Release の「latest」アセットとして
/// 配信され、各リリースの CI が署名付きで生成・添付する。
///
/// フィード URL は `releases/latest/download/<asset>` を使う。GitHub が常に
/// 最新リリースの同名アセットへ解決するため、固定 URL のまま最新版を指せる。
class DesktopUpdater {
  DesktopUpdater._();

  static const String _repo = 'Corevice/goroterm';
  static const String _macFeed =
      'https://github.com/$_repo/releases/latest/download/appcast-macos.xml';
  static const String _winFeed =
      'https://github.com/$_repo/releases/latest/download/appcast-windows.xml';

  /// 自動更新に対応するプラットフォームか。
  static bool get isSupported => Platform.isMacOS || Platform.isWindows;

  static String? get _feedUrl {
    if (Platform.isMacOS) return _macFeed;
    if (Platform.isWindows) return _winFeed;
    return null;
  }

  static bool _initialized = false;

  /// アプリ起動時に一度だけ呼ぶ。フィード URL を設定し、定期チェックを
  /// 有効化したうえで、起動直後にバックグラウンドで更新確認する。
  /// 更新があれば Sparkle / WinSparkle 標準のダイアログが表示される。
  static Future<void> init() async {
    final url = _feedUrl;
    if (url == null || _initialized) return;
    _initialized = true;
    try {
      await autoUpdater.setFeedURL(url);
      // 6 時間ごとに自動チェック(最小 3600 秒)。
      await autoUpdater.setScheduledCheckInterval(6 * 3600);
      // 起動直後の確認はバックグラウンド(更新が無ければ何も出さない)。
      await autoUpdater.checkForUpdates(inBackground: true);
    } catch (_) {
      // 署名鍵未設定・ネットワーク不通などは無視(手動チェックで再試行可能)。
    }
  }

  /// 設定画面などからの手動チェック。更新が無くても結果ダイアログを出す。
  static Future<void> checkNow() async {
    final url = _feedUrl;
    if (url == null) return;
    try {
      await autoUpdater.setFeedURL(url);
      await autoUpdater.checkForUpdates();
    } catch (_) {}
  }
}
