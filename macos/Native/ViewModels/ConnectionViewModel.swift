import AppKit
import Combine
import Foundation
import Network

@MainActor
final class ConnectionViewModel: ObservableObject {
    enum State: Equatable {
        case disconnected, starting, connected, stopping, failed
        var label: String {
            switch self {
            case .disconnected: return "未连接"
            case .starting: return "正在连接"
            case .connected: return "代理运行中"
            case .stopping: return "正在断开"
            case .failed: return "连接失败"
            }
        }
    }

    @Published private(set) var profiles: [ServerProfile] = []
    @Published var selectedID: UUID?
    @Published private(set) var activeCandidateIDs: Set<UUID> = []
    @Published private(set) var selectionMode = NodeSelectionMode.automatic
    @Published private(set) var manualID: UUID?
    @Published private(set) var state = State.disconnected
    @Published private(set) var logs: [LogEntry] = []
    @Published var errorMessage: String?
    @Published private(set) var systemProxyEnabled = false
    @Published private(set) var systemProxyBusy = false
    @Published private(set) var helperInstallation = ProxyHelperClient.InstallationState.notInstalled
    @Published private(set) var recoveryNeeded = false
    @Published private(set) var useTerminalProxy = false
    @Published private(set) var useTun = false
    var tunEnabled: Bool { state == .connected && engine.isTunRunning }
    @Published private(set) var terminalProxyEnabled = false
    @Published private(set) var terminalIntegrationInstalled = false
    @Published var useSystemProxy = false {
        didSet { defaults.set(useSystemProxy, forKey: "useSystemProxy") }
    }
    @Published var socksPort = 1081 {
        didSet { defaults.set(socksPort, forKey: "socksPort") }
    }
    @Published var httpPort = 1087 {
        didSet { defaults.set(httpPort, forKey: "httpPort") }
    }
    @Published private(set) var testing = false
    @Published private(set) var testResult: String?
    @Published private(set) var networkAvailable = true

    @Published private(set) var routingSettings: [String: Any] = ["defaultAction": "proxy", "rules": [[String: Any]]()]

    private var store: ProfileStore?
    private var instanceLock: InstanceLock?
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let coreExecutable: URL?
    private let engine = ProcessProxyEngine()
    private var systemProxy: SystemProxyController?
    private var terminalProxy: TerminalProxyManager?
    private var connectionTask: Task<Void, Never>?
    private var disconnecting = false
    private var disconnectTask: Task<Bool, Never>?
    private var proxyTask: Task<Void, Never>?
    private var exitRecoveryTask: Task<Void, Never>?
    private var appObserver: NSObjectProtocol?
    private var testTask: Task<Void, Never>?
    private var testID: UUID?
    private let monitor = NWPathMonitor()
    private var workspaceObservers: [NSObjectProtocol] = []

    var selectedProfile: ServerProfile? { profiles.first { $0.id == selectedID } }
    var candidates: [ServerProfile] { selectionMode.candidates(in: profiles, manualID: manualID) }
    var serviceEnabled: Bool { state == .connected || state == .starting }
    var canChangeSelection: Bool { !serviceEnabled && !busy }
    var connectionDescription: String {
        if selectionMode == .automatic {
            let count = activeCandidateIDs.isEmpty ? candidates.count : activeCandidateIDs.count
            return "自动选择 · \(count) 个候选节点"
        }
        return "手动选择 · \(profiles.first { $0.id == manualID }?.name ?? "请选择节点")"
    }
    var systemProxySwitch: Bool { state == .connected ? systemProxyEnabled : useSystemProxy }
    private var helperRefreshing = false
    var busy: Bool { state == .starting || state == .stopping || systemProxyBusy || exitRecoveryTask != nil }
    var ports: LocalPorts { LocalPorts(socks: socksPort, http: httpPort) }
    var terminalActivationCommand: String { terminalProxy?.activationCommand ?? "" }
    var canConnect: Bool { !candidates.isEmpty && !busy && state != .connected && !recoveryNeeded && store != nil && connectionTask == nil }

    init(directory: URL? = nil, defaults: UserDefaults = .standard, keychain: KeychainStore? = nil,
         coreExecutable: URL? = nil, terminalManager: TerminalProxyManager? = nil, observeEnvironment: Bool = true,
         proxyHelper: (any SystemProxyHelping)? = nil) {
        self.defaults = defaults
        self.keychain = keychain ?? KeychainStore()
        self.coreExecutable = coreExecutable
        selectionMode = NodeSelectionMode(rawValue: defaults.string(forKey: "nodeSelectionMode") ?? "") ?? .automatic
        manualID = defaults.string(forKey: "manualNodeID").flatMap(UUID.init(uuidString:))
        useSystemProxy = defaults.bool(forKey: "useSystemProxy")
        useTerminalProxy = defaults.bool(forKey: "useTerminalProxy")
        useTun = defaults.bool(forKey: "useTun")
        socksPort = defaults.object(forKey: "socksPort") as? Int ?? 1081
        httpPort = defaults.object(forKey: "httpPort") as? Int ?? 1087
        do {
            let store = try ProfileStore(directory: directory)
            instanceLock = try InstanceLock(directory: store.directory)
            self.store = store
            profiles = try store.load()
            let routingURL = store.directory.appendingPathComponent("routing.json")
            if FileManager.default.fileExists(atPath: routingURL.path) {
                let original = try Data(contentsOf: routingURL)
                guard let saved = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw ClientError.message("直连配置无效。") }
                routingSettings = try SingBoxConfiguration.directSettings(saved)
                if !NSDictionary(dictionary: saved).isEqual(to: routingSettings) {
                    let backup = store.directory.appendingPathComponent("routing-before-direct-config.json")
                    if !FileManager.default.fileExists(atPath: backup.path) {
                        try original.write(to: backup, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    }
                    try Self.persistRouting(routingSettings, at: routingURL)
                }
            }
            selectedID = profiles.first?.id
            if !profiles.contains(where: { $0.id == manualID }) { setManualNode(profiles.first?.id) }
            let proxy = SystemProxyController(directory: store.directory, helper: proxyHelper ?? ProxyHelperClient())
            systemProxy = proxy
            let terminal = terminalManager ?? TerminalProxyManager(directory: store.directory)
            terminalProxy = terminal
            try terminal.disable()
            terminalIntegrationInstalled = terminal.isInstalled
            if terminalIntegrationInstalled { try terminal.refreshScript() }
            recoveryNeeded = proxy.hasBackup
            if recoveryNeeded { log("检测到系统代理备份，请先恢复，再连接。") }
            // Remove credentials left on disk by interrupted previous sessions.
            for url in try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("run-") {
                try? FileManager.default.removeItem(at: url)
            }
        } catch { store = nil; errorMessage = "初始化失败：\(error.localizedDescription)" }
        engine.onLog = { [weak self] text in self?.log(text) }
        engine.onExit = { [weak self] status in self?.handleExit(status) }
        systemProxy?.helper.onConnectionLost = { [weak self] in
            guard let self else { return }
            self.systemProxyEnabled = false
            self.recoveryNeeded = self.systemProxy?.hasBackup == true
            self.log("后台辅助程序连接已中断；请恢复系统代理后重试。")
            // A rejected signature also invalidates XPC immediately. Reconnecting
            // here creates an unbounded invalidation/refresh loop after updates.
            // The next activation or explicit recovery performs one bounded check.
        }
        guard observeEnvironment else { return }
        appObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshHelperInstallation() }
        }
        Task { await refreshHelperInstallation() }
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.networkAvailable != available else { return }
                self.networkAvailable = available
                self.log(available ? "网络已恢复；新的请求将继续通过代理。" : "网络暂不可用，本地代理保持运行。")
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.lingj.shadowbat.network"))
        let center = NSWorkspace.shared.notificationCenter
        for (name, message) in [(NSWorkspace.willSleepNotification, "系统即将休眠。"),
                                (NSWorkspace.didWakeNotification, "系统已唤醒，代理会为新请求重新建立连接。") ] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.log(message) }
            })
        }
    }

    func password(for profile: ServerProfile) throws -> String { try keychain.read(profile.id) ?? "" }

    func setSelectionMode(_ mode: NodeSelectionMode) {
        guard canChangeSelection else { return }
        selectionMode = mode
        defaults.set(mode.rawValue, forKey: "nodeSelectionMode")
    }

    func setManualNode(_ id: UUID?) {
        guard canChangeSelection else { return }
        manualID = id
        defaults.set(id?.uuidString, forKey: "manualNodeID")
    }

    func setServiceEnabled(_ enabled: Bool) {
        if enabled { connect() }
        else if serviceEnabled { Task { await disconnect() } }
    }

    func setTun(_ enabled: Bool) throws {
        guard canChangeSelection else { throw ClientError.message("请先关闭代理服务，再切换 TUN 隧道。") }
        useTun = enabled
        defaults.set(enabled, forKey: "useTun")
    }

    func setAutomaticParticipation(_ enabled: Bool, for profile: ServerProfile) {
        do {
            guard canChangeSelection, let store else {
                throw ClientError.message("请先关闭代理服务，再修改正在使用的候选节点。")
            }
            var updated = profiles
            guard let index = updated.firstIndex(where: { $0.id == profile.id }) else { return }
            updated[index].participatesInAutomaticSelection = enabled
            try store.save(updated)
            profiles = updated
        } catch { errorMessage = error.localizedDescription }
    }

    func save(_ profile: ServerProfile, password: String) throws {
        guard canChangeSelection else { throw ClientError.message("请先关闭代理服务，再编辑此候选节点。") }
        try profile.validate(password: password)
        guard let store else { throw ClientError.message("节点存储不可用。") }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        let previousPassword = try keychain.read(profile.id)
        try keychain.save(password, for: profile.id)
        do { try store.save(updated) }
        catch {
            if let previousPassword { try? keychain.save(previousPassword, for: profile.id) }
            else { try? keychain.delete(profile.id) }
            throw error
        }
        profiles = updated
        selectedID = profile.id
        if manualID == nil { setManualNode(profile.id) }
        log("已保存节点「\(profile.name)」。")
    }

    func delete(_ profile: ServerProfile) {
        do {
            guard canChangeSelection, let store else { throw ClientError.message("请先关闭代理服务。") }
            let updated = profiles.filter { $0.id != profile.id }
            let password = try keychain.read(profile.id)
            try keychain.delete(profile.id)
            do { try store.save(updated) }
            catch { if let password { try? keychain.save(password, for: profile.id) }; throw error }
            profiles = updated
            if selectedID == profile.id { selectedID = profiles.first?.id }
            if manualID == profile.id { setManualNode(profiles.first?.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private static func persistRouting(_ settings: [String: Any], at url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func saveRouting(_ value: [String: Any]) throws {
        guard canChangeSelection, let store else { throw ClientError.message("请先断开连接，再修改直连配置。") }
        let settings = try SingBoxConfiguration.directSettings(value)
        try Self.persistRouting(settings, at: store.directory.appendingPathComponent("routing.json"))
        routingSettings = settings
    }

    func connect() {
        guard canConnect, let store else { return }
        let candidates = candidates
        errorMessage = nil
        testResult = nil
        state = .starting
        activeCandidateIDs = Set(candidates.map(\.id))
        let ports = ports
        connectionTask = Task {
            do {
                let servers = try candidates.map { profile in
                    let password = try self.password(for: profile)
                    guard !password.isEmpty else { throw ClientError.message("节点「\(profile.name)」缺少钥匙串密码，请编辑并重新保存。") }
                    return ProxyServer(profile: profile, password: password)
                }
                log("正在启动全局代理：\(connectionDescription)。")
                try await engine.start(servers: servers, ports: ports, directory: store.directory, executable: coreExecutable, routing: routingSettings, tun: useTun)
                try Task.checkCancellation()
                if useSystemProxy { try await enableSystemProxy() }
                try Task.checkCancellation()
                if useTerminalProxy { try enableTerminalProxy() }
                state = .connected
                log(useTun ? "TUN 隧道已启用，TCP / UDP 与 DNS 由虚拟网卡接管。" : "本地代理正在运行。可点击测试连接验证远端服务。")
            } catch {
                disableTerminalProxy()
                if systemProxy?.hasBackup == true {
                    do { try await restoreSystemProxy() }
                    catch { errorMessage = error.localizedDescription; recoveryNeeded = true }
                }
                await engine.stop()
                activeCandidateIDs = []
                if !(error is CancellationError) {
                    state = disconnecting ? .stopping : .failed
                    if errorMessage == nil { errorMessage = error.localizedDescription }
                    log("连接失败：\(error.localizedDescription)")
                } else { state = disconnecting ? .stopping : .disconnected }
            }
            connectionTask = nil
        }
    }

    func disconnect() async -> Bool {
        if let disconnectTask { return await disconnectTask.value }
        let task = Task { @MainActor in
            let result = await self.performDisconnect()
            self.disconnectTask = nil
            return result
        }
        disconnectTask = task
        return await task.value
    }

    private func performDisconnect() async -> Bool {
        disconnecting = true
        defer { disconnecting = false }
        state = .stopping
        connectionTask?.cancel()
        if let connectionTask { await connectionTask.value }
        if let proxyTask { await proxyTask.value }
        if let exitRecoveryTask { await exitRecoveryTask.value }
        testTask?.cancel()
        if let testTask { await testTask.value }
        testTask = nil
        testing = false
        state = .stopping
        do {
            try await restoreSystemProxy()
        } catch {
            recoveryNeeded = true
            errorMessage = error.localizedDescription
            state = engine.isRunning ? .connected : .failed
            return false
        }
        disableTerminalProxy()
        await engine.stop()
        activeCandidateIDs = []
        state = .disconnected
        log("已断开连接。")
        return true
    }

    func setSystemProxy(_ enabled: Bool) {
        guard !busy else { return }
        guard state == .connected else { useSystemProxy = enabled; return }
        systemProxyBusy = true
        proxyTask = Task {
            defer { systemProxyBusy = false; proxyTask = nil }
            do {
                if enabled { try await enableSystemProxy() }
                else { try await restoreSystemProxy() }
                useSystemProxy = enabled
            } catch {
                recoveryNeeded = systemProxy?.hasBackup == true
                errorMessage = error.localizedDescription
            }
        }
    }

    func recoverSystemProxy() {
        guard !busy else { return }
        errorMessage = nil
        systemProxyBusy = true
        proxyTask = Task {
            defer {
                helperInstallation = systemProxy?.helper.installation ?? .notInstalled
                systemProxyBusy = false
                proxyTask = nil
            }
            do { try await restoreSystemProxy(repairUnavailable: true); errorMessage = nil }
            catch {
                recoveryNeeded = systemProxy?.hasBackup == true
                errorMessage = error.localizedDescription
            }
        }
    }

    func installProxyHelper() {
        guard !busy, let systemProxy else { return }
        do {
            try systemProxy.helper.register()
            helperInstallation = systemProxy.helper.installation
            log(helperInstallation == .ready ? "系统代理辅助程序已授权。" : "请在系统设置中允许 Shadowbat 后台辅助程序。")
            if helperInstallation == .needsApproval { systemProxy.helper.openApprovalSettings() }
            Task { await refreshHelperInstallation() }
        } catch {
            helperInstallation = systemProxy.helper.installation
            errorMessage = error.localizedDescription
        }
    }

    func openHelperApprovalSettings() { systemProxy?.helper.openApprovalSettings() }

    func refreshHelperInstallation() async {
        guard let systemProxy, !helperRefreshing else { return }
        helperInstallation = systemProxy.helper.installation
        guard helperInstallation == .ready, !systemProxyBusy, !disconnecting, state != .starting else { return }
        helperRefreshing = true
        defer { helperRefreshing = false }
        do {
            try await systemProxy.refresh()
            if !systemProxyEnabled { recoveryNeeded = systemProxy.hasBackup }
        } catch { log("检查后台辅助程序失败：\(error.localizedDescription)") }
    }

    func installTerminalIntegration() {
        do { try installTerminal() }
        catch { errorMessage = error.localizedDescription }
    }

    func setTerminalProxy(_ enabled: Bool) {
        guard !busy else { return }
        do {
            if enabled {
                if !terminalIntegrationInstalled { try installTerminal() }
                if state == .connected { try enableTerminalProxy() }
            } else {
                try terminalProxy?.disable()
                terminalProxyEnabled = false
                log("终端代理已关闭；终端执行下一条命令前恢复原环境变量。")
            }
            useTerminalProxy = enabled
            defaults.set(enabled, forKey: "useTerminalProxy")
        } catch { errorMessage = error.localizedDescription }
    }

    private func installTerminal() throws {
        guard let terminalProxy else { throw ClientError.message("终端集成不可用。") }
        let backup = try terminalProxy.install()
        terminalIntegrationInstalled = terminalProxy.isInstalled
        if let backup { log("已备份 zsh 配置：\(backup.path)") }
        log("终端集成已安装。新终端自动加载；已有终端请执行一次激活命令。")
    }

    private func enableTerminalProxy() throws {
        guard let terminalProxy, let core = engine.process, core.isRunning else {
            throw ClientError.message("终端代理需要正在运行的代理内核。")
        }
        if !terminalProxy.isInstalled { try installTerminal() }
        try terminalProxy.enable(ports: ports, corePID: core.processIdentifier)
        terminalProxyEnabled = true
        log("终端代理已开启，HTTP \(httpPort)，SOCKS5 \(socksPort)；下一条命令前自动同步。")
    }

    private func disableTerminalProxy() {
        do { try terminalProxy?.disable() }
        catch { log("清理终端代理状态失败：\(error.localizedDescription)") }
        terminalProxyEnabled = false
    }

    private func enableSystemProxy() async throws {
        guard let systemProxy else { throw ClientError.message("系统代理管理不可用。") }
        let services = try await systemProxy.enable(ports: ports)
        systemProxyEnabled = true
        recoveryNeeded = false
        log("系统代理已开启：\(services.joined(separator: "、"))。")
    }

    private func restoreSystemProxy(repairUnavailable: Bool = false) async throws {
        guard let systemProxy, systemProxy.hasBackup else {
            systemProxyEnabled = false; recoveryNeeded = false; return
        }
        let skipped = try await systemProxy.restore(repairUnavailable: repairUnavailable)
        systemProxyEnabled = false
        recoveryNeeded = false
        if skipped.isEmpty { log("已恢复原系统代理设置。") }
        else { log("已恢复系统代理；保留了其他程序对以下服务的修改：\(skipped.joined(separator: "、"))。") }
    }

    private func handleExit(_ status: Int32) {
        guard state == .connected || state == .starting else { return }
        let wasStarting = state == .starting
        connectionTask?.cancel()
        disableTerminalProxy()
        testTask?.cancel()
        testing = false
        testID = nil
        state = .failed
        activeCandidateIDs = []
        if errorMessage == nil { errorMessage = "代理内核意外退出（\(status)）。" }
        log("代理内核已退出（\(status)）。")
        // The startup task owns rollback until it finishes; cancel it rather than race it.
        guard !wasStarting else { return }
        let pendingProxy = proxyTask
        exitRecoveryTask = Task {
            if let pendingProxy { await pendingProxy.value }
            systemProxyBusy = true
            defer { systemProxyBusy = false; exitRecoveryTask = nil }
            do { try await restoreSystemProxy() }
            catch { recoveryNeeded = true; errorMessage = error.localizedDescription }
        }
    }

    func testConnection() {
        guard state == .connected, !testing else { return }
        testing = true
        testResult = nil
        let port = httpPort
        let id = UUID()
        testID = id
        testTask = Task {
            defer {
                if testID == id { testing = false; testTask = nil; testID = nil }
            }
            let start = Date()
            do {
                _ = try await ConnectionProbe.request(url: URL(string: "https://www.apple.com/library/test/success.html")!, httpPort: port)
                guard testID == id else { return }
                let text = "连接测试成功，耗时 \(Int(Date().timeIntervalSince(start) * 1000)) ms。"
                testResult = text
                log(text)
            } catch {
                guard !Task.isCancelled, testID == id else { return }
                testResult = "测试失败：\(error.localizedDescription)"
                log(testResult!)
            }
        }
    }

    func clearLogs() { logs.removeAll() }

    func log(_ text: String) {
        logs.append(LogEntry(text: text))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }
}
