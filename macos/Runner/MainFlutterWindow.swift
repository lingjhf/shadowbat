import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private(set) var bridge: ShadowbatBridge!

  override func awakeFromNib() {
    ProxyHelperCommand.runIfRequested()
    let controller = FlutterViewController()
    contentViewController = controller
    title = "Shadowbat"
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    isReleasedWhenClosed = false
    contentMinSize = NSSize(width: 360, height: 640)
    contentAspectRatio = NSSize(width: 9, height: 16)
    setContentSize(NSSize(width: 360, height: 640))
    center()
    RegisterGeneratedPlugins(registry: controller)
    bridge = ShadowbatBridge(controller: controller, window: self)
    super.awakeFromNib()
  }
}
