import Cocoa
import Combine
import FlutterMacOS
import SwiftUI

/// One native model owns the core, credentials and both user interfaces.
@MainActor
final class ShadowbatBridge: NSObject, FlutterStreamHandler {
    let model: ConnectionViewModel
    private static let startupCheck = CommandLine.arguments.contains("--startup-check")
    #if DEBUG
    private static let previewMode = startupCheck || CommandLine.arguments.contains("--isolated-preview")
    #else
    private static let previewMode = startupCheck
    #endif
    private static func makeModel() -> ConnectionViewModel {
        if previewMode {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shadowbat-preview-\(ProcessInfo.processInfo.processIdentifier)")
            let defaults = UserDefaults(suiteName: "com.lingj.shadowbat.preview.\(ProcessInfo.processInfo.processIdentifier)")!
            return ConnectionViewModel(directory: directory, defaults: defaults,
                keychain: KeychainStore(service: "com.lingj.shadowbat.preview.passwords"),
                terminalManager: TerminalProxyManager(directory: directory, zshrc: directory.appendingPathComponent(".zshrc")),
                observeEnvironment: false)
        }
        return ConnectionViewModel()
    }
    private var methods: FlutterMethodChannel!
    private var events: FlutterEventChannel!
    private var sink: FlutterEventSink?
    private var observation: AnyCancellable?
    private var publishScheduled = false
    private var startupPublicationCount = 0
    private let logDateFormatter = ISO8601DateFormatter()
    private static let statusItemName = "com.lingj.shadowbat.status-item"
    private static let startupStatusItemName = "com.lingj.shadowbat.startup-status-item"
    private var statusItem: NSStatusItem!
    private var tray: NativeTrayPanel!
    private weak var mainWindow: NSWindow?

    init(controller: FlutterViewController, window: NSWindow) {
        model = Self.makeModel()
        super.init()
        mainWindow = window
        methods = FlutterMethodChannel(name: "com.lingj.shadowbat/commands", binaryMessenger: controller.engine.binaryMessenger)
        events = FlutterEventChannel(name: "com.lingj.shadowbat/state", binaryMessenger: controller.engine.binaryMessenger)
        events.setStreamHandler(self)
        methods.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in await self?.handle(call, result: result) }
        }
        observation = model.objectWillChange.sink { [weak self] in
            self?.schedulePublish()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.startupCheck ? Self.startupStatusItemName : Self.statusItemName
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleTray)
        statusItem.button?.toolTip = "Shadowbat"
        tray = NativeTrayPanel(content: TrayPanelView(model: model) { [weak self] in self?.showMainWindow() })
        publish()
        // AppKit persists visibility, including the temporary hide during quit.
        // Every normal launch must explicitly bring the menu bar item back.
        if Self.startupCheck && !statusItem.isVisible {
            FileHandle.standardOutput.write(Data("SHADOWBAT_STATUS_ITEM_RESTORED_HIDDEN\n".utf8))
        }
        statusItem.isVisible = true
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        publish()
        if Self.startupCheck {
            let previousPublicationCount = startupPublicationCount
            for index in 0..<500 { model.log("Startup fixture log \(index)") }
            // The real Flutter entry point has subscribed to the native state
            // stream. Allow its first UI update before finishing the smoke check.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                if CommandLine.arguments.contains("--seed-hidden-status-item") {
                    self.statusItem.isVisible = false
                    UserDefaults.standard.synchronize()
                    FileHandle.standardOutput.write(Data("SHADOWBAT_STATUS_ITEM_HIDDEN\n".utf8))
                    self.finishStartupCheck(success: true, keepStatusPreference: true)
                    return
                }
                let burstCoalesced = self.startupPublicationCount - previousPublicationCount <= 3
                if burstCoalesced {
                    FileHandle.standardOutput.write(Data("SHADOWBAT_LOG_BURST_OK\n".utf8))
                }
                let success = self.model.errorMessage == nil && self.statusItem.isVisible && self.statusItem.button?.image != nil && burstCoalesced
                let marker = success ? "SHADOWBAT_STARTUP_OK\n" : "SHADOWBAT_STARTUP_FAILED\n"
                FileHandle.standardOutput.write(Data(marker.utf8))
                if CommandLine.arguments.contains("--tray-position-check") {
                    self.checkTrayPosition(startupSuccess: success)
                    return
                }
                self.finishStartupCheck(success: success)
            }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }

    private func checkTrayPosition(startupSuccess: Bool) {
        toggleTray()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, let button = self.statusItem.button, let anchorWindow = button.window else {
                self?.finishStartupCheck(success: false)
                return
            }
            let content = self.tray.contentViewController.view
            guard let window = content.window else {
                self.finishStartupCheck(success: false)
                return
            }
            let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let frame = window.frame
            let body = window.convertToScreen(content.convert(content.bounds, to: nil))
            let below = body.maxY <= anchor.minY + 1 && frame.maxY <= anchor.minY + 4 && frame.maxY >= anchor.minY - 32
            let aligned = frame.minX <= anchor.midX && frame.maxX >= anchor.midX
            let responderReady = window.canBecomeKey && window.firstResponder === content
            let focusedWhenActive = !NSApp.isActive || (window.isKeyWindow && NSApp.keyWindow === window)
            let arrowless = window is NSPanel && window.styleMask == .borderless && frame.size == body.size
            if arrowless { FileHandle.standardOutput.write(Data("SHADOWBAT_TRAY_ARROWLESS_OK\n".utf8)) }
            let success = arrowless && startupSuccess && self.tray.isShown && below && aligned && responderReady && focusedWhenActive
            if responderReady && focusedWhenActive {
                FileHandle.standardOutput.write(Data("SHADOWBAT_TRAY_FOCUS_READY\n".utf8))
            }
            let marker = success ? "SHADOWBAT_TRAY_POSITION_OK\n" : "SHADOWBAT_TRAY_POSITION_FAILED\n"
            FileHandle.standardOutput.write(Data(marker.utf8))
            self.tray.close()
            self.finishStartupCheck(success: success)
        }
    }

    private func finishStartupCheck(success: Bool, keepStatusPreference: Bool = false) {
        let pid = ProcessInfo.processInfo.processIdentifier
        UserDefaults.standard.removePersistentDomain(forName: "com.lingj.shadowbat.preview.\(pid)")
        if !keepStatusPreference {
            statusItem.autosaveName = nil
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(Self.startupStatusItemName) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            UserDefaults.standard.synchronize()
        }
        // The isolated model has no connection or system integration to restore.
        exit(success ? 0 : 1)
    }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        // Collapse bursts of core logs and model changes into one current snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            self.publish()
        }
    }

    private func publish() {
        if Self.startupCheck { startupPublicationCount += 1 }
        let image = NSImage(systemSymbolName: model.state == .connected ? "network" : "network.slash", accessibilityDescription: model.state.label)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        statusItem.button?.image = image
        sink?(snapshot())
    }

    func snapshot() -> [String: Any] {
        [
            "platform": "macos", "routing": model.routingSettings,
            "tunSupported": true, "useTun": model.useTun, "tunEnabled": model.tunEnabled,
            "profiles": model.profiles.map { p in ["id": p.id.uuidString, "name": p.name, "host": p.host, "port": p.port, "method": p.method, "participatesInAutomaticSelection": p.participatesInAutomaticSelection] as [String: Any] },
            "selectedID": model.selectedID?.uuidString as Any? ?? NSNull(),
            "manualID": model.manualID?.uuidString as Any? ?? NSNull(),
            "activeCandidateIDs": model.activeCandidateIDs.map(\.uuidString),
            "selectionMode": model.selectionMode.rawValue,
            "state": String(describing: model.state), "stateLabel": model.state.label,
            "connectionDescription": model.connectionDescription,
            "serviceEnabled": model.serviceEnabled, "busy": model.busy,
            "canChangeSelection": model.canChangeSelection, "canConnect": model.canConnect,
            "serviceUnavailable": model.state == .stopping || model.systemProxyBusy || (!model.serviceEnabled && !model.canConnect),
            "systemProxyEnabled": model.systemProxyEnabled, "systemProxySwitch": model.systemProxySwitch,
            "useSystemProxy": model.useSystemProxy, "useTerminalProxy": model.useTerminalProxy,
            "terminalProxyEnabled": model.terminalProxyEnabled, "terminalIntegrationInstalled": model.terminalIntegrationInstalled,
            "helperInstallation": String(describing: model.helperInstallation), "helperLabel": model.helperInstallation.label,
            "recoveryNeeded": model.recoveryNeeded, "socksPort": model.socksPort, "httpPort": model.httpPort,
            "testing": model.testing, "testResult": model.testResult as Any? ?? NSNull(),
            "networkAvailable": model.networkAvailable, "errorMessage": model.errorMessage as Any? ?? NSNull(),
            "logs": model.logs.map { ["id": $0.id.uuidString, "date": logDateFormatter.string(from: $0.date), "text": $0.text] }
        ]
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let args = call.arguments as? [String: Any] ?? [:]
        do {
            if Self.previewMode && ["installProxyHelper", "recoverSystemProxy", "openApprovalSettings", "refreshHelper"].contains(call.method) {
                throw ClientError.message("隔离预览不操作系统代理授权。")
            }
            switch call.method {
            case "snapshot": result(snapshot()); return
            case "saveRouting": try model.saveRouting(args)
            case "setService": model.setServiceEnabled(try boolean(args))
            case "setTun": try model.setTun(try boolean(args))
            case "setSystemProxy": model.setSystemProxy(try boolean(args))
            case "setTerminalProxy": model.setTerminalProxy(try boolean(args))
            case "setSelectionMode":
                guard let mode = NodeSelectionMode(rawValue: args["value"] as? String ?? "") else { throw ClientError.message("未知节点选择模式。") }
                model.setSelectionMode(mode)
            case "setManualNode": model.setManualNode((args["id"] as? String).flatMap(UUID.init(uuidString:)))
            case "selectProfile": model.selectedID = (args["id"] as? String).flatMap(UUID.init(uuidString:))
            case "password": result(try model.password(for: try profile(args))); return
            case "saveProfile":
                guard let name = args["name"] as? String, let host = args["host"] as? String,
                      let port = args["port"] as? Int, let method = args["method"] as? String,
                      let password = args["password"] as? String else { throw ClientError.message("节点信息不完整。") }
                let id: UUID
                if let raw = args["id"] as? String {
                    guard let parsed = UUID(uuidString: raw) else { throw ClientError.message("无效节点标识。") }
                    id = parsed
                } else { id = UUID() }
                try model.save(ServerProfile(id: id, name: name, host: host, port: port, method: method,
                    participatesInAutomaticSelection: args["participatesInAutomaticSelection"] as? Bool ?? true), password: password)
            case "deleteProfile": model.delete(try profile(args))
            case "setParticipation": model.setAutomaticParticipation(try boolean(args), for: try profile(args))
            case "setPorts":
                guard model.canChangeSelection else { throw ClientError.message("请先关闭代理服务。") }
                guard let socks = args["socks"] as? Int, let http = args["http"] as? Int else { throw ClientError.message("无效端口。") }
                let ports = LocalPorts(socks: socks, http: http); try ports.validate()
                model.socksPort = socks; model.httpPort = http
            case "testConnection": model.testConnection()
            case "recoverSystemProxy": model.recoverSystemProxy()
            case "installProxyHelper": model.installProxyHelper()
            case "refreshHelper": await model.refreshHelperInstallation()
            case "openApprovalSettings": model.openHelperApprovalSettings()
            case "installTerminalIntegration": model.installTerminalIntegration()
            case "copyActivationCommand":
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.terminalActivationCommand, forType: .string)
            case "clearLogs": model.clearLogs()
            case "dismissError": model.errorMessage = nil
            default: result(FlutterMethodNotImplemented); return
            }
            result(nil)
            publish()
        } catch { result(FlutterError(code: "shadowbat", message: error.localizedDescription, details: nil)) }
    }

    private func boolean(_ args: [String: Any]) throws -> Bool {
        guard let value = args["value"] as? Bool else { throw ClientError.message("缺少开关值。") }; return value
    }
    private func profile(_ args: [String: Any]) throws -> ServerProfile {
        guard let raw = args["id"] as? String, let id = UUID(uuidString: raw), let p = model.profiles.first(where: { $0.id == id }) else { throw ClientError.message("节点不存在。") }; return p
    }
    @objc private func toggleTray() {
        guard let button = statusItem.button else { return }
        if tray.isShown { tray.close() }
        else { tray.showBelowStatusItem(button) }
    }
    func showMainWindow() {
        tray.close()
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func beginShutdown() {
        tray.close()
        mainWindow?.orderOut(nil)
        statusItem.isVisible = false
        NSApp.setActivationPolicy(.accessory)
    }
    func cancelShutdown() {
        statusItem.isVisible = true
        showMainWindow()
    }
}
