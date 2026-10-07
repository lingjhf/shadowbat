import Foundation
import ServiceManagement

@MainActor
protocol SystemProxyHelping: AnyObject {
    var installation: ProxyHelperClient.InstallationState { get }
    var onConnectionLost: (() -> Void)? { get set }
    func register() throws
    func openApprovalSettings()
    func status() async throws -> ProxyHelperStatus
    func enable(ports: LocalPorts) async throws -> ProxyHelperStatus
    func restore() async throws -> ProxyHelperStatus
    func repairInstallation() async throws
}

@MainActor
final class ProxyHelperClient: SystemProxyHelping {
    typealias UnregisterOperation = (@escaping @Sendable (Error?) -> Void) -> Void
    enum ConnectionFailure: LocalizedError {
        case interrupted, timedOut, unavailable(String), incompatible
        var errorDescription: String? {
            switch self {
            case .interrupted: return "系统代理辅助程序连接已中断；代理备份已保留，请重试恢复。"
            case .timedOut: return "后台辅助程序响应超时；代理备份已保留，请重试恢复。"
            case .unavailable(let detail): return "无法连接系统代理辅助程序：\(detail)"
            case .incompatible: return "后台辅助程序版本不兼容，请重试恢复以更新辅助程序。"
            }
        }
    }
    enum InstallationState {
        case notInstalled, needsApproval, ready, unavailable
        var label: String {
            switch self {
            case .notInstalled: return "尚未安装"
            case .needsApproval: return "等待系统授权"
            case .ready: return "已授权"
            case .unavailable: return "辅助程序不可用"
            }
        }
    }

    private let service = SMAppService.daemon(plistName: ProxyHelperIdentity.plistName)
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var pending: [UUID: CheckedContinuation<ProxyHelperStatus, Error>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var repairTask: Task<Void, Error>?
    private var unregisterPending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var unregisterTimers: [UUID: Task<Void, Never>] = [:]
    private let installationProvider: (() -> InstallationState)?
    private let connectionFactory: (() throws -> NSXPCConnection)?
    private let requestTimeout: Duration?
    private let unregisterOperation: UnregisterOperation?
    var onConnectionLost: (() -> Void)?

    init(installationProvider: (() -> InstallationState)? = nil,
         connectionFactory: (() throws -> NSXPCConnection)? = nil, requestTimeout: Duration? = nil,
         unregisterOperation: UnregisterOperation? = nil) {
        self.installationProvider = installationProvider
        self.connectionFactory = connectionFactory
        self.requestTimeout = requestTimeout
        self.unregisterOperation = unregisterOperation
    }

    var installation: InstallationState {
        if let installationProvider { return installationProvider() }
        switch service.status {
        case .notRegistered: return .notInstalled
        case .requiresApproval: return .needsApproval
        case .enabled: return .ready
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func register() throws {
        // Ad-hoc CI packages must never register an unauthenticated privileged daemon.
        _ = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier)
        guard installation != .ready else { return }
        try registerBundle()
    }

    private func registerBundle() throws {
        _ = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier)
        guard Bundle.main.bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons/\(ProxyHelperIdentity.plistName)").path) else {
            throw ClientError.message("App 中缺少后台辅助程序，请重新构建完整 App。")
        }
        do { try service.register() }
        catch {
            // macOS can register the service successfully while returning an approval-needed error.
            if installation != .needsApproval { throw error }
        }
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    func unregister() async throws {
        if installation == .ready {
            let current = try await status()
            guard !current.hasBackup else {
                throw ClientError.message("请先断开系统代理并恢复设置，再卸载后台辅助程序。")
            }
        }
        closeConnection()
        try await unregisterService()
    }

    /// Recovery after an app replacement must unload the old executable, rather
    /// than treating an enabled ServiceManagement registration as a healthy peer.
    /// Only explicit recovery calls this; durable root snapshots stay untouched.
    func repairInstallation() async throws {
        if let repairTask { return try await repairTask.value }
        let task = Task { @MainActor in
            _ = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier)
            closeConnection()
            if installation == .needsApproval {
                throw ClientError.message("请在系统设置 → 通用 → 登录项与扩展中允许 Shadowbat 后台辅助程序，然后重试恢复。")
            }
            if installation != .notInstalled { try await unregisterService() }
            try registerBundle()
            guard installation == .ready else {
                throw ClientError.message("辅助程序已更新，请在系统设置中允许 Shadowbat 后台辅助程序，然后重试恢复。")
            }
        }
        repairTask = task
        defer { repairTask = nil }
        try await task.value
    }

    private func unregisterService() async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            unregisterPending[id] = continuation
            unregisterTimers[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: self?.requestTimeout ?? .seconds(5)) } catch { return }
                self?.finishUnregister(id, .failure(ClientError.message("辅助程序更新超时；备份已保留，请重试恢复。")))
            }
            let completion: @Sendable (Error?) -> Void = { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.finishUnregister(id, error.map { .failure($0) } ?? .success(()))
                }
            }
            if let unregisterOperation { unregisterOperation(completion) }
            else { service.unregister(completionHandler: completion) }
        }
    }

    private func finishUnregister(_ id: UUID, _ result: Result<Void, Error>) {
        guard let continuation = unregisterPending.removeValue(forKey: id) else { return }
        unregisterTimers.removeValue(forKey: id)?.cancel()
        continuation.resume(with: result)
    }

    func status() async throws -> ProxyHelperStatus {
        try await request(timeout: .seconds(3)) { $0.status(withReply: $1) }
    }

    func enable(ports: LocalPorts) async throws -> ProxyHelperStatus {
        try ports.validate()
        return try await request(timeout: .seconds(10)) { $0.enable(socksPort: ports.socks, httpPort: ports.http, withReply: $1) }
    }

    func restore() async throws -> ProxyHelperStatus {
        try await request(timeout: .seconds(5)) { $0.restore(withReply: $1) }
    }

    private func request(timeout: Duration, _ invoke: (ProxyHelperProtocol, @escaping (Data?, String?) -> Void) -> Void) async throws -> ProxyHelperStatus {
        guard installation == .ready else {
            if installation == .needsApproval {
                throw ClientError.message("请在系统设置中允许 Shadowbat 后台辅助程序；授权后重试恢复。")
            }
            throw ConnectionFailure.unavailable("后台服务尚未注册或不可用，请重试恢复。")
        }
        let connection = try connected()
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timers[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: self?.requestTimeout ?? timeout) } catch { return }
                guard let self, self.pending[id] != nil else { return }
                self.finish(id, .failure(ConnectionFailure.timedOut))
                // Losing the connection revokes its proxy lease; the helper restores the backup.
                if self.connection === connection { self.closeConnection(notifyLoss: true) }
            }
            let reply: (Data?, String?) -> Void = { [weak self] data, message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        if let message { throw ClientError.message(message) }
                        guard let data else { throw ClientError.message("后台辅助程序返回了空结果。") }
                        let result = try JSONDecoder().decode(ProxyHelperStatus.self, from: data)
                        guard result.version == 1 else { throw ConnectionFailure.incompatible }
                        self.finish(id, .success(result))
                    } catch { self.finish(id, .failure(error)) }
                }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.finish(id, .failure(ConnectionFailure.unavailable(error.localizedDescription)))
                    if self.connection === connection { self.closeConnection(notifyLoss: true) }
                }
            }) as? ProxyHelperProtocol else {
                finish(id, .failure(ConnectionFailure.unavailable("XPC 接口不可用")))
                closeConnection(notifyLoss: true)
                return
            }
            invoke(proxy, reply)
        }
    }

    private func connected() throws -> NSXPCConnection {
        if let connection { return connection }
        let new: NSXPCConnection
        if let connectionFactory { new = try connectionFactory() }
        else {
            new = NSXPCConnection(machServiceName: ProxyHelperIdentity.serviceName, options: .privileged)
            // Authenticate the privileged peer as well as authenticating clients in the daemon.
            new.setCodeSigningRequirement(try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.serviceName))
        }
        new.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        let id = UUID()
        let lost = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == id else { return }
                self.closeConnection(notifyLoss: true)
            }
        }
        new.invalidationHandler = { _ = lost() }
        new.interruptionHandler = { _ = lost() }
        connection = new
        connectionID = id
        new.resume()
        return new
    }

    private func finish(_ id: UUID, _ result: Result<ProxyHelperStatus, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        continuation.resume(with: result)
    }

    private func closeConnection(notifyLoss: Bool = false) {
        let previous = connection
        connection = nil
        connectionID = nil
        previous?.invalidate()
        for id in Array(pending.keys) {
            finish(id, .failure(ConnectionFailure.interrupted))
        }
        if notifyLoss && previous != nil { onConnectionLost?() }
    }
}
