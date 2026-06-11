import Cocoa
import FlutterMacOS

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

  /// ウィンドウ → コントローラ。ウィンドウを閉じたらエンジンを停止する。
  private var controllers: [NSWindow: FlutterViewController] = [:]
  private var windowCounter = 0

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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func openSessionWindow(
    connectionId: Int, tmuxSessionName: String, label: String
  ) {
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

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = label
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 960, height: 640))
    window.delegate = self
    controllers[window] = controller

    // 既存ウィンドウと少しずらして表示する
    window.center()
    let offset = CGFloat((windowCounter % 8) * 24)
    window.setFrameOrigin(NSPoint(
      x: window.frame.origin.x + offset,
      y: window.frame.origin.y - offset))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          let controller = controllers.removeValue(forKey: window) else {
      return
    }
    // ウィンドウごとエンジンを停止して SSH 接続等のリソースを解放する
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

    super.awakeFromNib()
  }
}
