import Foundation
import Security
import SystemConfiguration

/// Writes only the proxy keys owned by Shadowbat; snapshots survive a crash.
@MainActor
final class SystemProxyManager {
    typealias Snapshot = ProxyServiceSnapshot

    private let backupURL: URL
    private var authorization: AuthorizationRef?

    init(directory: URL) {
        backupURL = directory.appendingPathComponent("system-proxy-backup.json")
    }

    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    static func settings(ports: LocalPorts) -> [String: Any] {
        ProxySettings.settings(socks: ports.socks, http: ports.http)
    }

    static func restored(current: [String: Any], original: [String: Any], applied: [String: Any]) -> ProxySettings.RestoreResult {
        ProxySettings.restored(current: current, original: original, applied: applied)
    }

    func enable(ports: LocalPorts) throws -> [String] {
        try ports.validate()
        guard !hasBackup else { throw ClientError.message("请先恢复上次保存的系统代理设置。") }
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, false) else { throw systemError("网络设置正在被其他程序修改") }
        defer { SCPreferencesUnlock(prefs) }
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw systemError("无法读取当前网络服务")
        }
        let applied = Self.settings(ports: ports)
        var snapshots: [Snapshot] = []
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  SCNetworkProtocolGetEnabled(proxies), let serviceID = SCNetworkServiceGetServiceID(service) else { continue }
            let original = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:]
            var merged = original
            applied.forEach { merged[$0.key] = $0.value }
            snapshots.append(Snapshot(
                serviceID: serviceID as String,
                serviceName: SCNetworkServiceGetName(service) as String? ?? "网络服务",
                original: try Self.encode(original), applied: try Self.encode(applied)))
            guard SCNetworkProtocolSetConfiguration(proxies, merged as CFDictionary) else {
                throw systemError("无法配置系统代理")
            }
        }
        guard !snapshots.isEmpty else { throw ClientError.message("没有可配置代理的网络服务。") }
        // Persist before committing so interrupted writes remain recoverable.
        try JSONEncoder().encode(snapshots).write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        guard SCPreferencesCommitChanges(prefs) else { throw systemError("保存系统代理失败") }
        guard SCPreferencesApplyChanges(prefs) else { throw systemError("应用系统代理失败，请使用恢复按钮重试") }
        return snapshots.map(\.serviceName)
    }

    func restore() throws -> [String] {
        guard hasBackup else { return [] }
        let snapshots = try JSONDecoder().decode([Snapshot].self, from: Data(contentsOf: backupURL))
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, false) else { throw systemError("网络设置正在被其他程序修改") }
        defer { SCPreferencesUnlock(prefs) }
        var skipped: [String] = []
        for snapshot in snapshots {
            guard let service = SCNetworkServiceCopy(prefs, snapshot.serviceID as CFString),
                  let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let current = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:]
            let restored = Self.restored(current: current, original: try Self.decode(snapshot.original),
                                         applied: try Self.decode(snapshot.applied))
            if restored.hadConflicts { skipped.append(snapshot.serviceName) }
            guard SCNetworkProtocolSetConfiguration(proxies, restored.configuration as CFDictionary) else {
                throw systemError("恢复系统代理失败")
            }
        }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw systemError("恢复系统代理失败，备份已保留")
        }
        try FileManager.default.removeItem(at: backupURL)
        return skipped
    }

    private func preferences() throws -> SCPreferences {
        if authorization == nil {
            let status = AuthorizationCreate(nil, nil, [], &authorization)
            guard status == errAuthorizationSuccess else { throw ClientError.message("无法创建系统授权：\(status)") }
        }
        guard let authorization else { throw ClientError.message("无法获取系统授权。") }
        let status = "system.preferences.network".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil,
                                               [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            throw ClientError.message(status == errAuthorizationCanceled ? "已取消系统代理授权。" : "系统代理授权失败：\(status)")
        }
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "Shadowbat" as CFString, nil, authorization) else {
            throw systemError("无法打开网络设置")
        }
        return prefs
    }

    private static func encode(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    private static func decode(_ data: Data) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ClientError.message("系统代理备份格式无效。")
        }
        return dictionary
    }

    private func systemError(_ operation: String) -> ClientError {
        let code = SCError()
        let detail = String(cString: SCErrorString(code))
        return .message("\(operation)：\(detail)")
    }
}
