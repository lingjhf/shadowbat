import Cocoa
import SwiftUI

@MainActor
final class TrayFocusFixtureAction: NSObject {
    var open: (() -> Void)?
    @objc func openTray(_ sender: Any?) { open?() }
}

@main
@MainActor
enum TrayPositionChecks {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shadowbat-tray-position-\(getpid())")
        let suite = "com.lingj.shadowbat.tray-position.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        let model = ConnectionViewModel(directory: directory, defaults: defaults,
            keychain: KeychainStore(service: suite),
            terminalManager: TerminalProxyManager(directory: directory, zshrc: directory.appendingPathComponent(".zshrc")),
            observeEnvironment: false)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "network.slash", accessibilityDescription: "Tray position fixture")
        item.isVisible = true
        let tray = NativeTrayPanel(content: TrayPanelView(model: model, openMainWindow: {}))
        let host = tray.contentViewController
        let interactive = CommandLine.arguments.contains("--interactive-focus")
        let check = {
          _ = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(300))
            guard let button = item.button, let window = button.window else { exit(1) }
            var success = true
            for (scene, mode, reopen) in [("first-open", NodeSelectionMode.automatic, true),
                                           ("mode-change", .manual, false), ("reopen", .automatic, true)] {
                model.setSelectionMode(mode)
                if reopen { tray.close() }
                try await Task.sleep(for: .milliseconds(100))
                let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
                if reopen { tray.showBelowStatusItem(button) }
                try await Task.sleep(for: .milliseconds(300))
                guard let popupWindow = host.view.window else { exit(1) }
                let frame = popupWindow.frame
                let content = popupWindow.convertToScreen(host.view.convert(host.view.bounds, to: nil))
                print("\(scene): flipped=\(button.isFlipped) size=\(tray.contentSize) frame=\(frame) content=\(content) anchor=\(anchor)")
                let arrowless = popupWindow is NSPanel && popupWindow.styleMask == .borderless && frame.size == content.size
                let below = content.maxY <= anchor.minY + 1 && frame.maxY <= anchor.minY + 4 && frame.maxY >= anchor.minY - 32
                let anchored = frame.minX <= anchor.midX && frame.maxX >= anchor.midX
                let focused = app.isActive && popupWindow.isKeyWindow && app.keyWindow === popupWindow
                let prepared = popupWindow.canBecomeKey && popupWindow.firstResponder === host.view
                print("\(scene): active=\(app.isActive) key=\(popupWindow.isKeyWindow) canBecomeKey=\(popupWindow.canBecomeKey) responder=\(String(describing: popupWindow.firstResponder))")
                // Background activation may be declined without a real user
                // gesture. Interactive checks require actual keyboard focus.
                let focusAllowed = interactive ? focused : (!app.isActive || focused)
                success = success && arrowless && tray.isShown && below && anchored && prepared && focusAllowed
            }
            if success {
                print(interactive ? "PASS: actual clicks open an anchored, active keyboard window" : "PASS: tray positioning and initial keyboard responder are ready")
            } else { print("FAIL: tray lost its anchor or keyboard focus") }
            if interactive && success { try await Task.sleep(for: .seconds(75)) }
            if !interactive {
                host.view.window?.cancelOperation(nil)
                success = success && !tray.isShown
                tray.showBelowStatusItem(button)
                let outside = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                       styleMask: .borderless, backing: .buffered, defer: false)
                let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: outside.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                let menu = NSMenu()
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
                app.postEvent(click, atStart: false)
                try await Task.sleep(for: .milliseconds(100))
                success = success && tray.isShown
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
                app.postEvent(click, atStart: false)
                try await Task.sleep(for: .milliseconds(100))
                success = success && !tray.isShown
                print(success ? "PASS: Escape and outside clicks dismiss; picker menu tracking stays open" : "FAIL: panel dismissal or menu tracking")
            }
            print("Panel visible after interactive inspection: \(tray.isShown)")
            tray.close()
            success = success && !tray.isShown
            NSStatusBar.system.removeStatusItem(item)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            exit(success ? 0 : 1)
          }
        }
        if interactive {
            let launcher = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
            launcher.title = "Shadowbat 托盘焦点测试"
            let action = TrayFocusFixtureAction()
            let button = NSButton(title: "打开托盘并检查焦点", target: action, action: #selector(TrayFocusFixtureAction.openTray(_:)))
            button.frame = NSRect(x: 70, y: 40, width: 240, height: 40)
            launcher.contentView?.addSubview(button)
            action.open = { launcher.orderOut(nil); check() }
            launcher.center()
            launcher.makeKeyAndOrderFront(nil)
            print("WAITING_FOR_FIXTURE_CLICK")
            withExtendedLifetime(action) { app.run() }
        } else {
            check()
            app.run()
        }
    }
}
