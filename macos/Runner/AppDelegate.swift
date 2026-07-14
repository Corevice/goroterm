import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate {
  /// 通知デリゲートに固定するメインエンジンの flutter_local_notifications
  /// プラグイン。tmux セッションごとに別 Flutter エンジンのウィンドウを開くと、
  /// プラグインは登録時に UNUserNotificationCenter.delegate を自身へ無条件で
  /// 差し替えるため、最後に登録した/既に閉じた分離ウィンドウのプラグインが
  /// デリゲートに残り、前面表示(willPresent)が働かず「アプリを触っている間に
  /// 別タブの通知がバナーで出ない」状態になっていた。これを保持して常に
  /// メインエンジンのプラグインへ戻す（強参照で生存も保証）。
  var stableNotificationDelegate: UNUserNotificationCenterDelegate?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
