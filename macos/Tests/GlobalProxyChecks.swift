import Foundation

@MainActor
enum GlobalProxyChecks {
    static func run(executable: URL, profile: ServerProfile, password: String, deadPort: Int,
                    ports: LocalPorts, directory: URL, terminal: TerminalProxyManager, url: String) async throws {
        let suite = "com.lingj.shadowbat.tests.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ClientError.message("Missing fixture preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: suite)
        let other = ServerProfile(name: "浏览的离线节点", host: "127.0.0.1", port: deadPort, method: "aes-256-gcm")
        defer { try? keychain.delete(profile.id); try? keychain.delete(other.id) }
        let modelDirectory = directory.appendingPathComponent("global-model")
        let model = ConnectionViewModel(directory: modelDirectory, defaults: defaults, keychain: keychain,
                                        coreExecutable: executable, terminalManager: terminal, observeEnvironment: false)
        try SmokeChecks.check(model.errorMessage == nil, "Global model could not initialize")
        try model.save(profile, password: password)
        try model.save(other, password: "offline-test-password")
        model.socksPort = ports.socks
        model.httpPort = ports.http
        model.setSystemProxy(true) // Arm only; never touches real system settings while disconnected.
        model.setTerminalProxy(true)
        model.setManualNode(profile.id)
        model.setSelectionMode(.manual)
        model.selectedID = other.id
        try SmokeChecks.check(model.candidates == [profile] && model.canConnect,
                              "Browsing a different node changed the manually fixed target")
        model.selectedID = nil
        model.setSelectionMode(.automatic)
        try SmokeChecks.check(model.candidates == [profile, other] && model.canConnect,
                              "Global service requires a sidebar selection in automatic mode")
        try SmokeChecks.check(model.useSystemProxy && model.useTerminalProxy && model.ports == ports,
                              "Browsing nodes or changing modes reset global proxy preferences")
        model.setSystemProxy(false) // Keep the isolated test entirely away from macOS network settings.
        model.setServiceEnabled(true)
        let deadline = Date().addingTimeInterval(20)
        while model.state == .starting && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        do {
            try SmokeChecks.check(model.state == .connected, "Global startup failed: \(model.errorMessage ?? "timeout")")
            try SmokeChecks.check(model.activeCandidateIDs == Set([profile.id, other.id]) && model.terminalProxyEnabled,
                                  "Global startup did not activate its candidate pool and terminal proxy")
            let stateBeforeBrowsing = try Data(contentsOf: terminal.stateFile)
            model.selectedID = other.id
            model.setSelectionMode(.manual)
            model.setManualNode(other.id)
            try SmokeChecks.check(model.selectionMode == .automatic && model.manualID == profile.id,
                                  "Active service changed selection without being stopped")
            let stateAfterBrowsing = try Data(contentsOf: terminal.stateFile)
            try SmokeChecks.check(model.serviceEnabled && stateBeforeBrowsing == stateAfterBrowsing,
                                  "Browsing a node restarted or reconfigured the global proxy")
            try SmokeChecks.curl(["--proxy", "http://127.0.0.1:\(ports.http)", url])
            model.setTerminalProxy(false)
            try SmokeChecks.check(model.serviceEnabled && !model.terminalProxyEnabled &&
                                  !FileManager.default.fileExists(atPath: terminal.stateFile.path),
                                  "Terminal switch stopped the global service or left environment state enabled")
            model.setTerminalProxy(true)
            try SmokeChecks.check(model.terminalProxyEnabled, "Terminal switch did not re-enable on the shared service")
            let disconnected = await model.disconnect()
            try SmokeChecks.check(disconnected && !model.serviceEnabled && model.activeCandidateIDs.isEmpty &&
                                  !model.terminalProxyEnabled && model.useTerminalProxy,
                                  "Global shutdown did not clear runtime state and retain the desired terminal setting")
            model.setSelectionMode(.manual)
            model.selectedID = other.id
            model.setServiceEnabled(true)
            let manualDeadline = Date().addingTimeInterval(10)
            while model.state == .starting && Date() < manualDeadline { try await Task.sleep(for: .milliseconds(50)) }
            try SmokeChecks.check(model.state == .connected && model.activeCandidateIDs == [profile.id],
                                  "Manual startup used the viewed node rather than the fixed target")
            try SmokeChecks.curl(["--proxy", "http://127.0.0.1:\(ports.http)", url])
            let stopped = await model.disconnect()
            try SmokeChecks.check(stopped, "Manual service could not stop")
            model.setServiceEnabled(true)
            let cancelled = await model.disconnect()
            try SmokeChecks.check(cancelled && model.state == .disconnected && model.activeCandidateIDs.isEmpty,
                                  "Rapid global on/off left a running service")
            try ProcessProxyEngine.checkAvailable(ports.socks)
            try ProcessProxyEngine.checkAvailable(ports.http)
            print("PASS: global switches and preferences, independent browsing/manual target, automatic startup without selection, terminal toggle and rapid on/off")
        } catch {
            _ = await model.disconnect()
            throw error
        }
    }
}
