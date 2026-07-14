import Cocoa
import FlutterMacOS
import UserNotifications

/// flutter_local_notifications は各 Flutter エンジンのプラグイン登録時に
/// UNUserNotificationCenter のデリゲートを自身へ無条件で差し替える。goroterm は
/// tmux セッションごとに別エンジンのウィンドウを開くため、放置すると最後に
/// 登録した/既に閉じた分離ウィンドウのプラグインがデリゲートに残り、前面表示
/// (willPresent)が働かず別タブの通知がバナーで出なくなる。プラグイン登録の
/// 直後にこれを呼び、デリゲートを常にメインエンジンのプラグインへ固定する。
/// メインのプラグインは presentBanner=true を尊重して前面でもバナーを出し、
/// 返信(text input)も native に処理する。
func pinNotificationDelegate(captureMain: Bool) {
  guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
  let center = UNUserNotificationCenter.current()
  if captureMain, appDelegate.stableNotificationDelegate == nil {
    // メイン登録直後: 現在のデリゲート(=メインエンジンのプラグイン)を捕捉。
    appDelegate.stableNotificationDelegate = center.delegate
  }
  if let stable = appDelegate.stableNotificationDelegate {
    center.delegate = stable
  }
}

/// FlutterViewController に共通の MethodChannel 群を登録する。
/// メインウィンドウと分離ウィンドウの両方で呼ばれる。
func registerCommonChannels(controller: FlutterViewController) {
  // クリップボード画像取得チャンネル
  let clipboardChannel = FlutterMethodChannel(
    name: "com.example.terminalSshApp/clipboard_image",
    binaryMessenger: controller.engine.binaryMessenger
  )
  clipboardChannel.setMethodCallHandler { (call, result) in
    if call.method == "getClipboardImage" {
      let pasteboard = NSPasteboard.general
      if let image = NSImage(pasteboard: pasteboard),
         let tiffData = image.tiffRepresentation,
         let bitmap = NSBitmapImageRep(data: tiffData),
         let pngData = bitmap.representation(using: .png, properties: [:]) {
        result(FlutterStandardTypedData(bytes: pngData))
      } else {
        result(nil)
      }
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  // タブ分離 (マルチウィンドウ) チャンネル
  DetachedWindowManager.shared.registerChannel(controller: controller)
}

/// タブ分離ウィンドウの生成と寿命管理。
///
/// Dart 側 (MacWindowService) から `openSessionWindow` を受けると、
/// 第二 Flutter エンジンを dartEntrypointArguments 付きで起動した
/// NSWindow を開く。新ウィンドウは自前の SSH 接続で同じ tmux セッションに
/// attach するため、エンジン間で状態を共有する必要はない。
class DetachedWindowManager: NSObject, NSWindowDelegate {
  static let shared = DetachedWindowManager()

  /// セッションウィンドウ共通の tabbing 識別子。同じ識別子のウィンドウ同士は
  /// macOS が 1 つのタブグループにまとめ、OS 標準のドラッグ切り離し・統合
  /// (Safari やターミナル.app と同じ挙動) を無料で提供する。
  static let sessionTabbingIdentifier =
    NSWindow.TabbingIdentifier("goroterm-session")

  /// ウィンドウ → コントローラ。ウィンドウを閉じたらエンジンを停止する。
  private var controllers: [NSWindow: FlutterViewController] = [:]
  /// 生成順のセッションウィンドウ。新規ウィンドウを既存グループのタブとして
  /// 追加する際のホスト探索に使う。
  private var sessionWindows: [NSWindow] = []
  /// 同一セッションの重複ウィンドウを防ぐためのキー (connectionId + 名前) →
  /// ウィンドウの対応。同じセッションを再度開こうとしたら既存にフォーカスする。
  private var sessionKeys: [NSWindow: String] = [:]
  /// タブに表示する基本名 (tmux セッション名)。スピナー表示時の復元に使う。
  private var tabBaseNames: [NSWindow: String] = [:]
  private var windowCounter = 0

  /// メインウィンドウ (接続一覧 / 接続タブ)。セッションウィンドウと同じタブ
  /// グループに参加させ、最初の tmux セッションもこのウィンドウのタブとして
  /// 合流させるためにホスト候補として使う。
  weak var mainWindow: NSWindow?

  /// Claude Code 稼働中のセッションキー集合と、スピナーアニメーション用タイマー。
  private var runningKeys: Set<String> = []
  private var spinnerTimer: Timer?
  private var spinnerFrame = 0
  private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  func registerChannel(controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.example.terminalSshApp/multi_window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "openSessionWindow":
        guard let args = call.arguments as? [String: Any],
              let connectionId = args["connectionId"] as? Int,
              let tmuxSessionName = args["tmuxSessionName"] as? String else {
          result(FlutterError(
            code: "bad_args",
            message: "connectionId and tmuxSessionName are required",
            details: nil))
          return
        }
        let label = args["label"] as? String ?? tmuxSessionName
        self.openSessionWindow(
          connectionId: connectionId,
          tmuxSessionName: tmuxSessionName,
          label: label)
        result(true)
      case "selectNextTab":
        // フォーカス中ウィンドウのタブグループで次のタブへ。
        NSApp.keyWindow?.selectNextTab(nil)
        result(true)
      case "selectPreviousTab":
        NSApp.keyWindow?.selectPreviousTab(nil)
        result(true)
      case "setTabRunning":
        guard let args = call.arguments as? [String: Any],
              let connectionId = args["connectionId"] as? Int,
              let tmuxSessionName = args["tmuxSessionName"] as? String,
              let running = args["running"] as? Bool else {
          result(false)
          return
        }
        let key = "\(connectionId)\u{0000}\(tmuxSessionName)"
        self.setTabRunning(key: key, running: running)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func openSessionWindow(
    connectionId: Int, tmuxSessionName: String, label: String
  ) {
    // 同一セッションが既に開いていれば新規作成せず、そのタブを前面に出す。
    let sessionKey = "\(connectionId)\u{0000}\(tmuxSessionName)"
    if let existing = sessionKeys.first(where: { $0.value == sessionKey })?.key {
      existing.makeKeyAndOrderFront(nil)
      existing.tabGroup?.selectedWindow = existing
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    windowCounter += 1

    // tmux セッション名は任意文字列のため base64 で渡す
    let tmuxB64 = Data(tmuxSessionName.utf8).base64EncodedString()
    let project = FlutterDartProject()
    project.dartEntrypointArguments = [
      "--detach-connection-id=\(connectionId)",
      "--detach-tmux-b64=\(tmuxB64)",
    ]

    // FlutterViewController(project:) が専用エンジンを生成して起動する
    let controller = FlutterViewController(project: project)
    RegisterGeneratedPlugins(registry: controller)
    registerCommonChannels(controller: controller)
    // 分離ウィンドウのプラグイン登録で奪われた通知デリゲートを、メイン
    // エンジンのプラグインへ戻す（前面バナーを安定させる）。
    pinNotificationDelegate(captureMain: false)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = label
    window.isReleasedWhenClosed = false
    // Flutter エンジンごと再生成されるセッションウィンドウは OS のウィンドウ復元
    // 対象にしない。再起動時に追跡外のゴーストウィンドウが復元されて、新規
    // セッションのタブ合流先判定と食い違うのを防ぐ。
    window.isRestorable = false
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 960, height: 640))
    window.delegate = self
    // OS 標準のウィンドウタブに参加させる。同じ識別子のセッションウィンドウ
    // 同士が 1 グループにまとまり、ドラッグでの切り離し・統合が OS 任せになる。
    window.tabbingIdentifier = DetachedWindowManager.sessionTabbingIdentifier
    // .preferred にすること。macOS の「タブの使用環境設定」が
    // "フルスクリーン時のみ"(inFullScreen) 等だと、.automatic は通常ウィンドウ
    // でのタブ統合を一切無効にしてしまう (実機 macOS 26 で確認)。.preferred は
    // このシステム設定を上書きし、通常ウィンドウでもドラッグでの切り離し・
    // 統合を有効にする。
    window.tabbingMode = .preferred
    controllers[window] = controller
    sessionKeys[window] = sessionKey
    sessionWindows.append(window)

    // 既存のセッションウィンドウがあれば、その上にタブとして追加する。
    // 無ければ単独ウィンドウとして開く。
    if let host = hostWindowForNewTab() {
      host.addTabbedWindow(window, ordered: .above)
      window.makeKeyAndOrderFront(nil)
    } else {
      window.center()
      let offset = CGFloat((windowCounter % 8) * 24)
      window.setFrameOrigin(NSPoint(
        x: window.frame.origin.x + offset,
        y: window.frame.origin.y - offset))
      window.makeKeyAndOrderFront(nil)
    }
    // タブが 1 枚でもタブバーを常時表示する。単独ウィンドウだとタブバーが
    // 隠れて「別タブのドロップ先」が見えず統合できないため、明示的に出す。
    forceShowTabBar(window)

    // タブ表示名は短い tmux セッション名にして省略を減らし、ホバーの
    // ツールチップに完全名 (label) を出す。
    tabBaseNames[window] = tmuxSessionName
    DispatchQueue.main.async { [weak window] in
      guard let window = window else { return }
      window.tab.title = tmuxSessionName
      window.tab.toolTip = label
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  /// sessionKey に対応するセッションウィンドウを返す。
  private func window(forSessionKey key: String) -> NSWindow? {
    return sessionKeys.first(where: { $0.value == key })?.key
  }

  /// タブの Claude Code 稼働インジケータ (スピナー) を更新する。
  private func setTabRunning(key: String, running: Bool) {
    if running {
      runningKeys.insert(key)
      if spinnerTimer == nil {
        spinnerTimer = Timer.scheduledTimer(
          withTimeInterval: 0.12, repeats: true
        ) { [weak self] _ in
          self?.tickSpinner()
        }
      }
    } else {
      runningKeys.remove(key)
      // 通常のタブ名に戻す。
      if let w = window(forSessionKey: key), let base = tabBaseNames[w] {
        w.tab.title = base
      }
      if runningKeys.isEmpty {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
      }
    }
  }

  private func tickSpinner() {
    spinnerFrame = (spinnerFrame + 1) % spinnerFrames.count
    let frame = spinnerFrames[spinnerFrame]
    for key in runningKeys {
      if let w = window(forSessionKey: key), let base = tabBaseNames[w] {
        w.tab.title = "\(frame) \(base)"
      }
    }
  }

  /// ウィンドウのタブバーが隠れていれば表示する（ドロップ先を常に見せる）。
  ///
  /// makeKeyAndOrderFront/addTabbedWindow の直後に同期で toggleTabBar を
  /// 呼ぶとタイミングが早すぎてタブバーが出ないことがある (実機で確認)。
  /// 次のラン ループまで遅延させてから判定・表示する。
  private func forceShowTabBar(_ window: NSWindow) {
    DispatchQueue.main.async { [weak window] in
      guard let window = window else { return }
      if window.tabGroup?.isTabBarVisible == false {
        window.toggleTabBar(nil)
      }
    }
  }

  /// 新規セッションウィンドウを追加するタブグループのホストを返す。
  /// (1) フォーカス中がセッションウィンドウ or メインウィンドウならそれ、
  /// (2) z-order 最前面の可視セッションウィンドウ（現在の Space が選ばれやすい）、
  /// (3) 既存セッションウィンドウ、(4) 無ければメインウィンドウ(接続タブ) に
  /// 合流させる。これで最初の tmux セッションも接続ウィンドウのタブになる。
  private func hostWindowForNewTab() -> NSWindow? {
    if let key = NSApp.keyWindow, key.isVisible,
       controllers[key] != nil || key == mainWindow {
      return key
    }
    if let front = NSApp.orderedWindows.first(where: {
      controllers[$0] != nil && $0.isVisible
    }) {
      return front
    }
    if let lastSession = sessionWindows.last(where: { $0.isVisible }) {
      return lastSession
    }
    if let main = mainWindow, main.isVisible {
      return main
    }
    return nil
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          controllers[window] != nil else { return }
    // タブを切り離して単独になったウィンドウはタブバーが隠れるため、
    // フォーカスが当たったタイミングで出し直してドロップ先を見せ続ける。
    if (window.tabGroup?.windows.count ?? 1) <= 1 {
      forceShowTabBar(window)
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          let controller = controllers.removeValue(forKey: window) else {
      return
    }
    sessionWindows.removeAll(where: { $0 == window })
    if let key = sessionKeys.removeValue(forKey: window) {
      runningKeys.remove(key)
      if runningKeys.isEmpty {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
      }
    }
    tabBaseNames.removeValue(forKey: window)
    // ウィンドウごとにエンジンを停止して SSH 接続等のリソースを解放する
    controller.engine.shutDownEngine()
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerCommonChannels(controller: flutterViewController)

    // メインエンジンのプラグインを捕捉し、通知デリゲートをそこに固定する
    // （前面バナーの安定化）。
    pinNotificationDelegate(captureMain: true)

    // メインウィンドウ(接続一覧 / 接続タブ)も tmux セッションウィンドウと
    // 同じ OS タブグループに参加させる。これで「接続」と各 tmux セッションが
    // 1 つのウィンドウのタブとしてまとまり、最初の tmux セッションが単独
    // ウィンドウで飛び出さない。識別子を揃え、.preferred で通常ウィンドウ
    // でもドラッグ切り離し・統合を有効にする。
    self.tabbingIdentifier = DetachedWindowManager.sessionTabbingIdentifier
    self.tabbingMode = .preferred
    DetachedWindowManager.shared.mainWindow = self

    // セッションウィンドウは復元できない (Flutter エンジンごと作り直すため)。
    // メインウィンドウも復元対象から外し、再起動時に復元ウィンドウが
    // セッションタブ合流判定と食い違うのを防ぐ。
    self.isRestorable = false

    super.awakeFromNib()
  }
}
