import Foundation

struct ProxyServiceSnapshot: Codable {
    let serviceID: String
    let serviceName: String
    let original: Data
    let applied: Data
}

enum ProxySettings {
    static func validate(socks: Int, http: Int) throws {
        guard (1024...65535).contains(socks), (1024...65535).contains(http), socks != http else {
            throw NSError(domain: ProxyHelperIdentity.serviceName, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "本地端口应为 1024–65535，且 SOCKS5 与 HTTP 端口不能相同。"])
        }
    }

    static func settings(socks: Int, http: Int) -> [String: Any] {
        ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": socks,
         "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": http,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": http,
         "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
         "ExcludeSimpleHostnames": 1, "ExceptionsList": ["localhost", "127.0.0.1", "::1", "*.local"]]
    }

    struct RestoreResult {
        let configuration: [String: Any]
        let hadConflicts: Bool
    }

    static func restored(current: [String: Any], original: [String: Any], applied: [String: Any]) -> RestoreResult {
        var result = current
        var conflicts = false
        let groups = [["HTTPEnable", "HTTPProxy", "HTTPPort"],
                      ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"],
                      ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"],
                      ["ProxyAutoConfigEnable"], ["ProxyAutoDiscoveryEnable"],
                      ["ExcludeSimpleHostnames"], ["ExceptionsList"]]
        for group in groups {
            guard group.allSatisfy({ key in
                guard let expected = applied[key], let value = current[key] else { return false }
                return (value as AnyObject).isEqual(expected)
            }) else { conflicts = true; continue }
            for key in group {
                if let value = original[key] { result[key] = value }
                else { result.removeValue(forKey: key) }
            }
        }
        return RestoreResult(configuration: result, hadConflicts: conflicts)
    }
}
