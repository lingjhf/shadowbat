import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var terminating = false
  private var closeObserver: NSObjectProtocol?
  private var bridge: ShadowbatBridge? { (mainFlutterWindow as? MainFlutterWindow)?.bridge }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: mainFlutterWindow, queue: .main) { _ in
      DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    bridge?.showMainWindow()
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = bridge?.model else { return .terminateNow }
    guard !terminating else { return .terminateCancel }
    terminating = true
    Task { @MainActor in
      let safe = await model.disconnect()
      if !safe {
        bridge?.showMainWindow()
        let alert = NSAlert()
        alert.messageText = "系统代理尚未恢复"
        alert.informativeText = "为避免网络请求指向已停止的代理，请先恢复系统代理，再退出。"
        alert.addButton(withTitle: "返回应用")
        alert.runModal()
      }
      terminating = false
      sender.reply(toApplicationShouldTerminate: safe)
    }
    return .terminateLater
  }
}
