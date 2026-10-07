import Foundation

/// Emits the native backend's production TUN config for the isolated Python harness.
@main
@MainActor
enum TunConfiguration {
    static func main() throws {
        let profile = ServerProfile(name: "Isolated TUN fixture", host: "127.0.0.1", port: 23456, method: "aes-256-gcm")
        let settings: [String: Any] = ["rules": [["id": "direct-fixture", "type": "ip", "target": "198.18.0.124", "action": "direct", "enabled": true]]]
        let config = try SingBoxConfiguration.make(servers: [ProxyServer(profile: profile, password: "temporary-tun-fixture-password")],
                                                   ports: LocalPorts(socks: 23457, http: 23458), settings: settings,
                                                   probeURL: "http://localhost/", interval: "1m", tun: true)
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]))
    }
}
