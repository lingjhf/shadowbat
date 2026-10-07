import Darwin
import Foundation

@MainActor
enum AutomaticSelectionChecks {
    static func run(executable: URL, profile: ServerProfile, password: String,
                    secondPort: Int, secondPID: Int32, deadPort: Int, apiPort: Int,
                    ports: LocalPorts, directory: URL, terminal: TerminalProxyManager, url: String) async throws {
        let secondPassword = "second-temporary-test-password"
        let second = ServerProfile(name: "快速候选", host: "127.0.0.1", port: secondPort, method: "aes-256-gcm")
        let unavailable = ServerProfile(name: "离线候选", host: "127.0.0.1", port: deadPort, method: "aes-256-gcm")
        var excluded = second
        excluded.id = UUID()
        excluded.participatesInAutomaticSelection = false
        let profiles = [unavailable, profile, second, excluded]
        // Viewing a node must not determine the automatic pool; manual selection is independent.
        try SmokeChecks.check(NodeSelectionMode.automatic.candidates(in: profiles, manualID: excluded.id) ==
                              [unavailable, profile, second], "Automatic pool depends on selected node or includes excluded node")
        try SmokeChecks.check(NodeSelectionMode.manual.candidates(in: profiles, manualID: excluded.id) == [excluded],
                              "Manual mode cannot use a node excluded from automatic selection")
        try SmokeChecks.check(NodeSelectionMode.manual.candidates(in: profiles, manualID: nil).isEmpty,
                              "Manual mode silently chose a different node")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        oldJSON.removeValue(forKey: "participatesInAutomaticSelection")
        let migrated = try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try SmokeChecks.check(migrated == profile, "Legacy profile migration failed")
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(excluded))
        try SmokeChecks.check(!decoded.participatesInAutomaticSelection, "Excluded state was not persisted")

        let engine = ProcessProxyEngine(probeURL: "http://probe.shadowbat.test/", probeInterval: "1s", testAPIPort: apiPort)
        var logs: [String] = []
        engine.onLog = { logs.append($0) }
        do {
            try await engine.start(servers: [], ports: ports, directory: directory, executable: executable)
            throw ClientError.message("Empty candidate pool started a core")
        } catch {
            try SmokeChecks.check(!engine.isRunning, "Empty pool left a core running")
        }
        do {
            try await engine.start(servers: [ProxyServer(profile: profile, password: password),
                                             ProxyServer(profile: second, password: "")],
                                   ports: ports, directory: directory, executable: executable)
            throw ClientError.message("Missing candidate password accepted")
        } catch {
            try SmokeChecks.check(!engine.isRunning, "Invalid candidate left a core running")
        }
        try await engine.start(servers: [ProxyServer(profile: unavailable, password: "offline-test-password"),
                                         ProxyServer(profile: profile, password: password),
                                         ProxyServer(profile: second, password: secondPassword)],
                               ports: ports, directory: directory, executable: executable)
        do {
            guard let pid = engine.process?.processIdentifier else { throw ClientError.message("Missing multi-node core") }
            try terminal.enable(ports: ports, corePID: pid)
            let originalTerminalState = try Data(contentsOf: terminal.stateFile)
            let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("run-") }
            try SmokeChecks.check(folders.count == 1, "Multiple cores/configurations created for automatic selection")
            let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: folders[0].appendingPathComponent("config.json"))) as! [String: Any]
            try SmokeChecks.check((configuration["outbounds"] as? [[String: Any]])?.filter { $0["type"] as? String == "shadowsocks" }.count == 3,
                                  "Candidate configurations were not sent to the shared core")
            // Wait for a successful encrypted request: the first candidate is offline,
            // so success proves that urltest selected a reachable node.
            var selected = false
            for _ in 0..<30 {
                do { try SmokeChecks.curl(["--proxy", "http://127.0.0.1:\(ports.http)", url]); selected = true; break }
                catch { try await Task.sleep(for: .milliseconds(200)) }
            }
            try SmokeChecks.check(selected, "Core did not select a reachable candidate")
            func selectedNode() async -> String? {
                guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(apiPort)/proxies/proxy")!),
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return state["now"] as? String
            }
            for _ in 0..<60 {
                if await selectedNode() == "node-\(second.id.uuidString)" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let initialSelection = await selectedNode()
            try SmokeChecks.check(initialSelection == "node-\(second.id.uuidString)", "URL test did not select the faster candidate: \(initialSelection ?? "nil")")
            try SmokeChecks.curl(["--socks5-hostname", "127.0.0.1:\(ports.socks)", url])
            kill(secondPID, SIGTERM)
            try await Task.sleep(for: .milliseconds(300))
            var failedOver = false
            for _ in 0..<30 {
                do { try SmokeChecks.curl(["--proxy", "http://127.0.0.1:\(ports.http)", url]); failedOver = true; break }
                catch { try await Task.sleep(for: .milliseconds(200)) }
            }
            try SmokeChecks.check(failedOver, "Core did not fail over to the remaining reachable candidate")
            let fallbackSelection = await selectedNode()
            try SmokeChecks.check(fallbackSelection == "node-\(profile.id.uuidString)", "Failover selected the wrong candidate")
            try SmokeChecks.check(engine.process?.processIdentifier == pid && engine.isRunning,
                                  "Failover restarted the global proxy service")
            let terminalState = try Data(contentsOf: terminal.stateFile)
            try SmokeChecks.check(terminalState == originalTerminalState, "Node failover changed terminal proxy state")
            try TerminalProxyChecks.request(manager: terminal, corePID: pid, ports: ports, url: url)
            try SmokeChecks.curl(["--proxy", "http://127.0.0.1:\(ports.http)", "--proxytunnel", url])
            try SmokeChecks.check(!logs.joined().contains(password) && !logs.joined().contains(secondPassword),
                                  "Candidate logs leaked credentials")
            try terminal.disable()
            await engine.stop()
            print("PASS: legacy profiles, independent selection, candidate exclusion, automatic health selection and failover; shared ports/PID/terminal state")
        } catch {
            try? terminal.disable()
            await engine.stop()
            throw error
        }
    }
}
