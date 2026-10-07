import Foundation

@MainActor
enum RoutingChecks {
    static func run(profile: ServerProfile, password: String, ports: LocalPorts, directory: URL) throws {
        let direct: [String: Any] = ["id": "domain", "type": "domain", "target": " LOCALHOST. ", "action": "direct", "enabled": true]
        let disabled: [String: Any] = ["id": "disabled", "type": "ip", "target": "101.33.73.2", "action": "direct", "enabled": false]
        let legacyProxy: [String: Any] = ["id": "proxy", "type": "suffix", "target": "example.com", "action": "proxy", "enabled": true]
        let legacy: [String: Any] = ["defaultAction": "direct", "rules": [direct, disabled, legacyProxy]]
        let normalized = try SingBoxConfiguration.directSettings(legacy)
        let rules = normalized["rules"] as! [[String: Any]]
        try SmokeChecks.check(normalized["defaultAction"] as? String == "proxy" && rules.count == 2,
                              "Legacy policy did not normalize to direct exceptions")
        try SmokeChecks.check(rules[0]["target"] as? String == "localhost", "Domain did not normalize")
        for (type, target) in [("domain", "https://example.com"), ("ip", "999.1.2.3"), ("cidr", "::/129")] {
            try SmokeChecks.mustThrow("Invalid \(type) rule accepted") {
                _ = try SingBoxConfiguration.directSettings(["rules": [["id": "bad", "type": type, "target": target, "action": "direct"]]])
            }
        }
        try SmokeChecks.mustThrow("Duplicate rule IDs accepted") {
            _ = try SingBoxConfiguration.directSettings(["rules": [direct, direct]])
        }
        let config = try SingBoxConfiguration.make(servers: [ProxyServer(profile: profile, password: password)], ports: ports,
                                                   settings: legacy, probeURL: "http://localhost/", interval: "1s")
        let route = config["route"] as! [String: Any], dns = config["dns"] as! [String: Any]
        var tunConfig = try SingBoxConfiguration.make(servers: [ProxyServer(profile: profile, password: password)], ports: ports,
                                                      settings: legacy, probeURL: "http://localhost/", interval: "1s", tun: true)
        try TunConfigurationValidator.validate(tunConfig)
        tunConfig["log"] = ["output": "/tmp/unapproved-root-output"]
        try SmokeChecks.mustThrow("Privileged configuration accepted arbitrary file output") { try TunConfigurationValidator.validate(tunConfig) }
        let routeRules = route["rules"] as! [[String: Any]]
        try SmokeChecks.check(route["final"] as? String == "proxy" && routeRules.count == 4,
                              "Disabled or legacy proxy rule entered runtime policy")
        try SmokeChecks.check((dns["rules"] as! [[String: Any]]).first?["server"] as? String == "bootstrap",
                              "Direct domain DNS did not use local resolver")
        let suite = "com.lingj.shadowbat.routing-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = directory.appendingPathComponent("routing-model")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let routingURL = folder.appendingPathComponent("routing.json")
        let original = try JSONSerialization.data(withJSONObject: legacy)
        try original.write(to: routingURL)
        let model = ConnectionViewModel(directory: folder, defaults: defaults, observeEnvironment: false)
        try SmokeChecks.check(model.errorMessage == nil, "Routing model initialization failed")
        try model.setTun(true)
        try SmokeChecks.check(model.useTun && defaults.bool(forKey: "useTun") && !model.tunEnabled, "TUN preference did not persist independently of connection")
        let backup = try Data(contentsOf: folder.appendingPathComponent("routing-before-direct-config.json"))
        try SmokeChecks.check(backup == original, "Legacy routing backup was lost")
        try model.saveRouting(["rules": [disabled]])
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: routingURL)) as! [String: Any]
        try SmokeChecks.check((saved["rules"] as! [[String: Any]]).count == 1, "Direct rule did not persist")
        let attributes = try FileManager.default.attributesOfItem(atPath: routingURL.path)
        try SmokeChecks.check(attributes[.posixPermissions] as? Int == 0o600, "Unsafe routing file permissions")
        print("PASS: macOS direct rules, validation, DNS policy, legacy backup and private persistence")
    }
}
