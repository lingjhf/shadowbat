import Foundation
import ServiceManagement

@MainActor
final class ProxyHelperClient {
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
    var onConnectionLost: (() -> Void)?

    var installation: InstallationState {
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
        try await service.unregister()
    }

    func status() async throws -> ProxyHelperStatus {
        try await request { $0.status(withReply: $1) }
    }

    func enable(ports: LocalPorts) async throws -> ProxyHelperStatus {
        try ports.validate()
        return try await request { $0.enable(socksPort: ports.socks, httpPort: ports.http, withReply: $1) }
    }

    func restore() async throws -> ProxyHelperStatus {
        try await request { $0.restore(withReply: $1) }
    }

    private func request(_ invoke: (ProxyHelperProtocol, @escaping (Data?, String?) -> Void) -> Void) async throws -> ProxyHelperStatus {
        guard installation == .ready else {
            throw ClientError.message(installation == .needsApproval
                ? "请在系统设置中允许 Shadowbat 后台辅助程序；授权后再开启系统代理。"
                : "请先安装并授权系统代理辅助程序。")
        }
        let connection = try connected()
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timers[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.pending[id] != nil else { return }
                self.finish(id, .failure(ClientError.message("后台辅助程序响应超时，请检查后台授权。")))
                // Losing the connection revokes its proxy lease; the helper restores the backup.
                if self.connection === connection { self.closeConnection() }
            }
            let reply: (Data?, String?) -> Void = { [weak self] data, message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        if let message { throw ClientError.message(message) }
                        guard let data else { throw ClientError.message("后台辅助程序返回了空结果。") }
                        let result = try JSONDecoder().decode(ProxyHelperStatus.self, from: data)
                        guard result.version == 1 else { throw ClientError.message("后台辅助程序版本不兼容，请更新安装。") }
                        self.finish(id, .success(result))
                    } catch { self.finish(id, .failure(error)) }
                }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { @MainActor [weak self] in self?.finish(id, .failure(error)) }
            }) as? ProxyHelperProtocol else {
                finish(id, .failure(ClientError.message("无法连接系统代理辅助程序。")))
                return
            }
            invoke(proxy, reply)
        }
    }

    private func connected() throws -> NSXPCConnection {
        if let connection { return connection }
        let new = NSXPCConnection(machServiceName: ProxyHelperIdentity.serviceName, options: .privileged)
        // Authenticate the privileged peer as well as authenticating clients in the daemon.
        new.setCodeSigningRequirement(try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.serviceName))
        new.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        let id = UUID()
        let lost = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == id else { return }
                self.closeConnection()
                self.onConnectionLost?()
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

    private func closeConnection() {
        let previous = connection
        connection = nil
        connectionID = nil
        previous?.invalidate()
        for id in Array(pending.keys) {
            finish(id, .failure(ClientError.message("系统代理辅助程序连接已中断，后台程序会尝试恢复代理。")))
        }
    }
}
