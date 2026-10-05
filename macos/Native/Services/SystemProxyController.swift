import Darwin
import Foundation

/// New changes go through the daemon. The old manager is only for one-time legacy recovery.
@MainActor
final class SystemProxyController {
    let helper = ProxyHelperClient()
    private let legacy: SystemProxyManager
    private let receipt: URL
    private var helperHasBackup = false
    private var generation = 0

    init(directory: URL) {
        legacy = SystemProxyManager(directory: directory)
        receipt = directory.appendingPathComponent("helper-proxy-session")
    }

    var hasBackup: Bool {
        legacy.hasBackup || helperHasBackup || FileManager.default.fileExists(atPath: receipt.path)
    }

    func refresh() async throws {
        guard helper.installation == .ready else { return }
        let generation = generation
        let status = try await helper.status()
        guard self.generation == generation else { return }
        helperHasBackup = status.hasBackup && status.ownerUID == getuid()
        if !helperHasBackup { try removeReceipt() }
    }

    func enable(ports: LocalPorts) async throws -> [String] {
        guard helper.installation == .ready else { throw ClientError.message("请先安装并授权系统代理辅助程序。") }
        guard !legacy.hasBackup else { throw ClientError.message("请先恢复旧版系统代理设置，再使用后台辅助程序。") }
        guard !hasBackup else { throw ClientError.message("请先恢复上次保存的系统代理设置。") }
        generation += 1
        // Persist intent before the request: an ambiguous XPC failure must stay recoverable.
        try Data("1\n".utf8).write(to: receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        do {
            let status = try await helper.enable(ports: ports)
            helperHasBackup = status.hasBackup
            return status.serviceNames
        } catch {
            // If a status call succeeds, it disambiguates a failure before any privileged write.
            try? await refresh()
            throw error
        }
    }

    func restore() async throws -> [String] {
        generation += 1
        var conflicts: [String] = []
        if legacy.hasBackup { conflicts += try legacy.restore() }
        if helperHasBackup || FileManager.default.fileExists(atPath: receipt.path) {
            let status = try await helper.restore()
            helperHasBackup = status.hasBackup && status.ownerUID == getuid()
            conflicts += status.conflicts
            if !helperHasBackup { try removeReceipt() }
        }
        return conflicts
    }

    private func removeReceipt() throws {
        if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
    }
}
