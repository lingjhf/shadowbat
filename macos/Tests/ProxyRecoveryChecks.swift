import Cocoa

@MainActor
private final class RecoveryHelper: SystemProxyHelping {
    var installation = ProxyHelperClient.InstallationState.ready
    var onConnectionLost: (() -> Void)?
    var repaired = false
    var statusCalls = 0
    var restoreCalls = 0
    var repairCalls = 0
    var failStatus = true
    var failRepair = false
    var conflict = false
    var shouldSuspend = false
    func register() throws {}
    func openApprovalSettings() {}
    func status() async throws -> ProxyHelperStatus {
        statusCalls += 1
        if failStatus {
            onConnectionLost?()
            throw ProxyHelperClient.ConnectionFailure.interrupted
        }
        return ProxyHelperStatus(hasBackup: false, active: false, ownerUID: nil)
    }
    func enable(ports: LocalPorts) async throws -> ProxyHelperStatus { fatalError("No system writes in recovery fixtures") }
    func restore() async throws -> ProxyHelperStatus {
        restoreCalls += 1
        if shouldSuspend { try await Task.sleep(for: .milliseconds(50)) }
        if conflict { throw ClientError.message("另一个 Shadowbat 连接正在使用系统代理。") }
        guard repaired else { throw ProxyHelperClient.ConnectionFailure.interrupted }
        return ProxyHelperStatus(hasBackup: false, active: false, ownerUID: nil)
    }
    func repairInstallation() async throws {
        repairCalls += 1
        if failRepair {
            installation = .needsApproval
            throw ClientError.message("请重新允许后台辅助程序。")
        }
        repaired = true
    }
}

// An anonymous in-process XPC endpoint tests the real client's timers without
// contacting the installed root daemon or changing network preferences.
private final class SilentPeer: NSObject, NSXPCListenerDelegate, ProxyHelperProtocol {
    let listener = NSXPCListener.anonymous()
    var connections: [NSXPCConnection] = []
    var replies: [(Data?, String?) -> Void] = []
    override init() { super.init(); listener.delegate = self; listener.resume() }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        connection.exportedObject = self
        connections.append(connection)
        connection.resume()
        return true
    }
    func status(withReply reply: @escaping (Data?, String?) -> Void) { replies.append(reply) }
    func enable(socksPort: Int, httpPort: Int, withReply reply: @escaping (Data?, String?) -> Void) { replies.append(reply) }
    func restore(withReply reply: @escaping (Data?, String?) -> Void) { replies.append(reply) }
    func close() { for connection in connections { connection.invalidate() }; listener.invalidate() }
}

@main
@MainActor
enum ProxyRecoveryChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ClientError.message(message) }
    }
    static func waitForRecovery(_ model: ConnectionViewModel) async throws {
        let deadline = Date().addingTimeInterval(2)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(!model.busy, "Recovery never released the busy state")
    }
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        app.run()
    }
    static func run() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shadowbat-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "com.lingj.shadowbat.recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func fixture(_ name: String, helper: RecoveryHelper) throws -> (ConnectionViewModel, URL) {
            let directory = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let receipt = directory.appendingPathComponent("helper-proxy-session")
            try Data("1\n".utf8).write(to: receipt)
            let model = ConnectionViewModel(directory: directory, defaults: defaults,
                keychain: KeychainStore(service: suite),
                terminalManager: TerminalProxyManager(directory: directory, zshrc: directory.appendingPathComponent(".zshrc")),
                observeEnvironment: false, proxyHelper: helper)
            return (model, receipt)
        }
        let helper = RecoveryHelper()
        let (model, receipt) = try fixture("replacement", helper: helper)
        try check(model.recoveryNeeded, "Receipt did not require recovery")
        await model.refreshHelperInstallation()
        try await Task.sleep(for: .milliseconds(100))
        try check(helper.statusCalls == 1, "Rejected XPC recursively reconnected")
        helper.shouldSuspend = true
        model.recoverSystemProxy()
        model.recoverSystemProxy()
        try await waitForRecovery(model)
        try check(helper.repairCalls == 1 && helper.restoreCalls == 2, "Repair was skipped or repeated")
        try check(!model.recoveryNeeded && model.errorMessage == nil && !FileManager.default.fileExists(atPath: receipt.path),
                  "Successful replacement recovery did not release the UI or remove its receipt")
        print("PASS: rejected XPC does not reconnect in a loop; explicit recovery reloads once and clears stale state")

        let denied = RecoveryHelper(); denied.failRepair = true
        let (deniedModel, deniedReceipt) = try fixture("approval", helper: denied)
        deniedModel.recoverSystemProxy()
        try await waitForRecovery(deniedModel)
        try check(deniedModel.recoveryNeeded && deniedModel.helperInstallation == .needsApproval && deniedModel.errorMessage != nil,
                  "Approval failure did not surface or release UI")
        try check(FileManager.default.fileExists(atPath: deniedReceipt.path), "Repair failure discarded the recovery receipt")
        denied.failRepair = false; denied.installation = .ready
        deniedModel.recoverSystemProxy()
        try await waitForRecovery(deniedModel)
        try check(!deniedModel.recoveryNeeded && deniedModel.errorMessage == nil, "A failed repair could not be retried")

        let conflict = RecoveryHelper(); conflict.conflict = true
        let (conflictModel, conflictReceipt) = try fixture("conflict", helper: conflict)
        conflictModel.recoverSystemProxy()
        try await waitForRecovery(conflictModel)
        try check(conflict.repairCalls == 0 && conflictModel.recoveryNeeded && FileManager.default.fileExists(atPath: conflictReceipt.path),
                  "A lease conflict restarted the daemon or discarded its receipt")
        let stale = RecoveryHelper(); stale.failStatus = false
        let (staleModel, staleReceipt) = try fixture("stale", helper: stale)
        await staleModel.refreshHelperInstallation()
        try check(!staleModel.recoveryNeeded && !FileManager.default.fileExists(atPath: staleReceipt.path),
                  "Healthy status did not clear an already-restored receipt")
        print("PASS: failed repair remains retryable, approval status updates, conflicts preserve leases, completed recovery clears stale receipts")

        let peer = SilentPeer()
        defer { peer.close() }
        var factoryCalls = 0
        let client = ProxyHelperClient(installationProvider: { .ready }, connectionFactory: {
            factoryCalls += 1
            return NSXPCConnection(listenerEndpoint: peer.listener.endpoint)
        }, requestTimeout: .milliseconds(100))
        var losses = 0
        client.onConnectionLost = { losses += 1 }
        let start = Date()
        async let first = outcome { try await client.status() }
        async let second = outcome { try await client.restore() }
        let results = await [first, second]
        try check(results.allSatisfy { $0 } && peer.replies.count == 2 && Date().timeIntervalSince(start) >= 0.08 && Date().timeIntervalSince(start) < 1,
                  "A silent XPC peer left a continuation waiting")
        try check(factoryCalls == 1 && losses == 1, "Timeout recursively connected or lost more than once")
        // Late completion after invalidation must not resume a continuation twice.
        let data = try JSONEncoder().encode(ProxyHelperStatus(hasBackup: false, active: false, ownerUID: nil))
        for reply in peer.replies { reply(data, nil) }
        try await Task.sleep(for: .milliseconds(50))
        let retried = await outcome { try await client.status() }
        try check(retried && factoryCalls == 2, "A timed-out connection could not be retried")
        print("PASS: real XPC request timeouts finish overlapping waiters; late replies are harmless and retries create a fresh connection")
        var completion: (@Sendable (Error?) -> Void)?
        let stalledService = ProxyHelperClient(installationProvider: { .notInstalled }, requestTimeout: .milliseconds(100),
            unregisterOperation: { completion = $0 })
        let serviceStart = Date()
        var serviceTimedOut = false
        do { try await stalledService.unregister() }
        catch { serviceTimedOut = error.localizedDescription.contains("辅助程序更新超时") }
        try check(serviceTimedOut && Date().timeIntervalSince(serviceStart) >= 0.08 && Date().timeIntervalSince(serviceStart) < 1,
                  "Silent ServiceManagement callback did not finish with a timeout")
        completion?(nil)
        try await Task.sleep(for: .milliseconds(50))
        print("PASS: ServiceManagement callback has a deadline and ignores late completions")
    }
    static func outcome(_ work: () async throws -> ProxyHelperStatus) async -> Bool {
        do { _ = try await work(); return false }
        catch is ProxyHelperClient.ConnectionFailure { return true }
        catch { return false }
    }
}
