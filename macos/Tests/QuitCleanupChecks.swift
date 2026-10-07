import Cocoa

// The real AppDelegate is compiled with a minimal Flutter/window adapter so the
// test exercises AppKit termination without loading personal application data.
class FlutterAppDelegate: NSObject, NSApplicationDelegate {
    var mainFlutterWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

@MainActor
final class ShutdownFixtureModel {
    let engine = ProcessProxyEngine()
    func disconnect() async -> Bool {
        await engine.stop()
        print("SHUTDOWN_COMPLETE")
        return true
    }
}

@MainActor
final class ShadowbatBridge {
    let model = ShutdownFixtureModel()
    func beginShutdown() { print("SHUTDOWN_REQUESTED") }
    func cancelShutdown() {}
    func showMainWindow() {}
}

@MainActor
final class MainFlutterWindow: NSWindow {
    let bridge = ShadowbatBridge()
}

@main
@MainActor
enum QuitCleanupChecks {
    static func main() {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count == 5, let socks = Int(args[2]), let http = Int(args[3]) else { exit(1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(), window = MainFlutterWindow()
        delegate.mainFlutterWindow = window
        app.delegate = delegate
        Task { @MainActor in
            do {
                let profile = ServerProfile(name: "Quit fixture", host: "127.0.0.1", port: 65534, method: "aes-256-gcm")
                try await window.bridge.model.engine.start(profile: profile, password: "temporary-cleanup-fixture",
                    ports: LocalPorts(socks: socks, http: http), directory: URL(fileURLWithPath: args[4]),
                    executable: URL(fileURLWithPath: args[1]))
                print("READY")
                // Dispatching quit mirrors an AppKit menu/button action.
                DispatchQueue.main.async { app.terminate(nil) }
            } catch {
                print("FIXTURE_FAILED: \(error)")
                exit(1)
            }
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
