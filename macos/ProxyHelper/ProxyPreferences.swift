import Foundation
import SystemConfiguration

protocol ProxyPreferences {
    func enable(socks: Int, http: Int, save: ([ProxyServiceSnapshot]) throws -> Void) throws -> [String]
    func restore(_ services: [ProxyServiceSnapshot]) throws -> [String]
}

final class SystemProxyPreferences: ProxyPreferences {
    func enable(socks: Int, http: Int, save: ([ProxyServiceSnapshot]) throws -> Void) throws -> [String] {
        try locked { preferences in
            guard let set = SCNetworkSetCopyCurrent(preferences),
                  let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { throw failure("无法读取网络服务") }
            let applied = ProxySettings.settings(socks: socks, http: http)
            var snapshots: [ProxyServiceSnapshot] = []
            for service in services where SCNetworkServiceGetEnabled(service) {
                guard let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                      SCNetworkProtocolGetEnabled(proxies), let id = SCNetworkServiceGetServiceID(service) else { continue }
                let original = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:]
                var merged = original
                applied.forEach { merged[$0.key] = $0.value }
                snapshots.append(ProxyServiceSnapshot(serviceID: id as String,
                    serviceName: SCNetworkServiceGetName(service) as String? ?? "网络服务",
                    original: try encode(original), applied: try encode(applied)))
                guard SCNetworkProtocolSetConfiguration(proxies, merged as CFDictionary) else { throw failure("设置代理失败") }
            }
            guard !snapshots.isEmpty else { throw failure("没有可配置代理的网络服务") }
            try save(snapshots)
            try commit(preferences)
            return snapshots.map(\.serviceName)
        }
    }

    func restore(_ services: [ProxyServiceSnapshot]) throws -> [String] {
        try locked { preferences in
            var conflicts: [String] = []
            for item in services {
                guard let service = SCNetworkServiceCopy(preferences, item.serviceID as CFString),
                      let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
                let current = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:]
                let result = ProxySettings.restored(current: current, original: try decode(item.original), applied: try decode(item.applied))
                if result.hadConflicts { conflicts.append(item.serviceName) }
                guard SCNetworkProtocolSetConfiguration(proxies, result.configuration as CFDictionary) else { throw failure("恢复代理失败") }
            }
            try commit(preferences)
            return conflicts
        }
    }

    private func locked<T>(_ work: (SCPreferences) throws -> T) throws -> T {
        guard let preferences = SCPreferencesCreate(nil, "Shadowbat Proxy Helper" as CFString, nil),
              SCPreferencesLock(preferences, false) else { throw failure("网络设置正被其他程序修改") }
        defer { SCPreferencesUnlock(preferences) }
        return try work(preferences)
    }

    private func commit(_ preferences: SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences) else { throw failure("保存代理设置失败") }
        guard SCPreferencesApplyChanges(preferences) else { throw failure("应用代理设置失败，备份已保留") }
    }

    private func encode(_ settings: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
    }
    private func decode(_ data: Data) throws -> [String: Any] {
        guard let settings = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw failure("代理备份格式不正确")
        }
        return settings
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: ProxyHelperIdentity.serviceName, code: Int(SCError()),
                userInfo: [NSLocalizedDescriptionKey: "\(message)：\(String(cString: SCErrorString(SCError())))"])
    }
}
