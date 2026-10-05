import Darwin
import Foundation

@main
@MainActor
enum SmokeChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ClientError.message(message) }
    }

    static func mustThrow(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw ClientError.message(message)
    }

    static func curl(_ arguments: [String], succeeds: Bool = true) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--fail", "--max-time", "5", "--noproxy", ""] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if succeeds {
            try check(process.terminationStatus == 0, "Proxy request failed: \(String(decoding: data, as: UTF8.self).prefix(300))")
            try check(String(decoding: data, as: UTF8.self) == "shadowbat-test-response", "Unexpected proxy response")
        } else { try check(process.terminationStatus != 0, "Proxy unexpectedly bypassed the stopped Shadowsocks server") }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let arguments = CommandLine.arguments
        guard arguments.count == 10,
              let serverPort = Int(arguments[2]), let socksPort = Int(arguments[3]),
              let httpPort = Int(arguments[4]), let fixturePort = Int(arguments[5]),
              let serverPID = Int32(arguments[6]), let secondPort = Int(arguments[7]),
              let secondPID = Int32(arguments[8]), let deadPort = Int(arguments[9]) else { throw ClientError.message("Invalid test arguments") }
        let executable = URL(fileURLWithPath: arguments[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shadowbat-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        let bundledScript = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/terminal-proxy.zsh")
        let scriptResource = FileManager.default.fileExists(atPath: bundledScript.path) ? bundledScript :
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Native/Resources/terminal-proxy.zsh")
        let terminal = try TerminalProxyChecks.run(directory: directory, resource: scriptResource)
        let password = "temporary-shadowbat-test-password"
        let profile = ServerProfile(name: "测试节点", host: "127.0.0.1", port: serverPort, method: "aes-256-gcm")
        try profile.validate(password: password)
        try store.save([profile])
        let loaded = try store.load()
        try check(loaded == [profile], "Profile persistence failed")
        let rawProfile = try String(contentsOf: directory.appendingPathComponent("profiles.json"), encoding: .utf8)
        try check(!rawProfile.contains(password) && !rawProfile.contains("password"), "Profile leaked credentials")
        var invalid = profile
        invalid.port = 0
        try mustThrow("Invalid server port accepted") { try invalid.validate(password: password) }
        invalid = profile
        invalid.method = "2022-blake3-aes-128-gcm"
        try mustThrow("Invalid AEAD-2022 key accepted") { try invalid.validate(password: password) }
        try invalid.validate(password: Data(repeating: 1, count: 16).base64EncodedString())
        try mustThrow("Duplicate listener ports accepted") { try LocalPorts(socks: socksPort, http: socksPort).validate() }

        let original: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "original.example", "HTTPPort": 8000,
                                       "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://pac.example/config",
                                       "ExceptionsList": ["private.example"], "Unrelated": "preserved"]
        let applied = SystemProxyManager.settings(ports: LocalPorts(socks: socksPort, http: httpPort))
        var current = original
        applied.forEach { current[$0.key] = $0.value }
        let restored = SystemProxyManager.restored(current: current, original: original, applied: applied)
        try check(NSDictionary(dictionary: restored.configuration).isEqual(to: original), "Proxy restoration failed")
        try check(!restored.hadConflicts, "Unexpected proxy conflict")
        current["SOCKSProxy"] = "other.example"
        current["Unrelated"] = "new-value"
        let merged = SystemProxyManager.restored(current: current, original: original, applied: applied)
        try check(merged.hadConflicts && merged.configuration["SOCKSProxy"] as? String == "other.example", "Concurrent proxy edit overwritten")
        try check(merged.configuration["HTTPProxy"] as? String == "original.example", "Untouched HTTP proxy not restored")
        try check(merged.configuration["Unrelated"] as? String == "new-value", "Unrelated edit lost")

        var lock: InstanceLock? = try InstanceLock(directory: directory)
        try check(lock != nil, "Instance lock not acquired")
        try mustThrow("A second app instance acquired the lock") { _ = try InstanceLock(directory: directory) }
        lock = nil
        let reacquired = try InstanceLock(directory: directory)
        _ = reacquired

        let keychain = KeychainStore(service: "com.lingj.shadowbat.tests.\(UUID())")
        let credentialID = UUID()
        defer { try? keychain.delete(credentialID) }
        try keychain.save(password, for: credentialID)
        let storedPassword = try keychain.read(credentialID)
        try check(storedPassword == password, "Keychain read failed")
        try keychain.save("updated", for: credentialID)
        let updatedPassword = try keychain.read(credentialID)
        try check(updatedPassword == "updated", "Keychain update failed")
        try keychain.delete(credentialID)
        let deletedPassword = try keychain.read(credentialID)
        try check(deletedPassword == nil, "Keychain deletion failed")
        print("PASS: profile validation, persistence, Keychain, and conflict-safe proxy restoration")

        let ports = LocalPorts(socks: socksPort, http: httpPort)
        let url = "http://fixture.shadowbat.test:\(fixturePort)/"
        try await AutomaticSelectionChecks.run(executable: executable, profile: profile, password: password,
                                               secondPort: secondPort, secondPID: secondPID, deadPort: deadPort,
                                               ports: ports, directory: directory, terminal: terminal, url: url)
        try await GlobalProxyChecks.run(executable: executable, profile: profile, password: password,
                                       deadPort: deadPort, ports: ports, directory: directory, terminal: terminal, url: url)
        let engine = ProcessProxyEngine()
        var logs: [String] = []
        engine.onLog = { logs.append($0) }
        var exitStatus: Int32?
        engine.onExit = { exitStatus = $0 }
        try await engine.start(profile: profile, password: password, ports: ports, directory: directory, executable: executable)
        try check(engine.isRunning, "Core not running")
        let runDirectories = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("run-") }
        try check(runDirectories.count == 1, "No runtime config")
        let permissions = try FileManager.default.attributesOfItem(atPath: runDirectories[0].appendingPathComponent("config.json").path)
        try check(permissions[.posixPermissions] as? Int == 0o600, "Unsafe config permissions")
        try mustThrow("Occupied SOCKS port accepted") { try ProcessProxyEngine.checkAvailable(socksPort) }
        let second = ProcessProxyEngine()
        do {
            try await second.start(profile: profile, password: password, ports: ports, directory: directory, executable: executable)
            throw ClientError.message("Second core accepted occupied ports")
        } catch let error as ClientError {
            try check(error.localizedDescription.contains("已被占用"), "Wrong port conflict failure")
        }
        // Only the test Shadowsocks server can resolve this host via its private fixture DNS.
        try TerminalProxyChecks.request(manager: terminal, corePID: engine.process!.processIdentifier, ports: ports, url: url)
        try curl(["--socks5-hostname", "127.0.0.1:\(socksPort)", url])
        try curl(["--proxy", "http://127.0.0.1:\(httpPort)", url])
        try curl(["--proxy", "http://127.0.0.1:\(httpPort)", "--proxytunnel", url])
        let (probeData, _) = try await ConnectionProbe.request(url: URL(string: url)!, httpPort: httpPort)
        try check(String(decoding: probeData, as: UTF8.self) == "shadowbat-test-response", "App connection probe failed")
        try check(!logs.joined().contains(password), "Core logs leaked credentials")
        print("PASS: signed bundled core; encrypted SOCKS5, HTTP, and CONNECT requests")

        // A request must fail after its Shadowsocks server is gone: no silent direct fallback.
        kill(serverPID, SIGTERM)
        try await Task.sleep(for: .milliseconds(300))
        try curl(["--socks5-hostname", "127.0.0.1:\(socksPort)", url], succeeds: false)
        try curl(["--proxy", "http://127.0.0.1:\(httpPort)", url], succeeds: false)
        do {
            _ = try await ConnectionProbe.request(url: URL(string: url)!, httpPort: httpPort)
            throw ClientError.message("App connection probe bypassed stopped server")
        } catch let error as ClientError {
            if error.localizedDescription.contains("bypassed") { throw error }
        } catch { }
        print("PASS: unreachable upstream fails without bypassing the proxy")
        if let pid = engine.process?.processIdentifier { kill(pid, SIGTERM) }
        for _ in 0..<40 {
            if exitStatus != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(exitStatus != nil && !engine.isRunning, "Unexpected core exit not handled")
        try check(!FileManager.default.fileExists(atPath: runDirectories[0].path), "Runtime credentials left after exit")
        try await engine.start(profile: profile, password: password, ports: ports, directory: directory, executable: executable)
        await engine.stop()
        try ProcessProxyEngine.checkAvailable(socksPort)
        try ProcessProxyEngine.checkAvailable(httpPort)
        try check(!engine.isRunning, "Core remained after disconnect")

        // Even with a multi-node pool, losing every candidate must never bypass encryption.
        let offline = ServerProfile(name: "离线候选", host: "127.0.0.1", port: deadPort, method: "aes-256-gcm")
        try await engine.start(servers: [ProxyServer(profile: profile, password: password),
                                         ProxyServer(profile: offline, password: "offline-test-password")],
                               ports: ports, directory: directory, executable: executable)
        try curl(["--socks5-hostname", "127.0.0.1:\(socksPort)", url], succeeds: false)
        try curl(["--proxy", "http://127.0.0.1:\(httpPort)", url], succeeds: false)
        await engine.stop()
        print("PASS: all automatic candidates unavailable; no direct fallback")

        do {
            try await engine.start(profile: profile, password: password, ports: ports, directory: directory,
                                   executable: URL(fileURLWithPath: "/usr/bin/false"))
            throw ClientError.message("Invalid core startup accepted")
        } catch {
            try check(!engine.isRunning, "Failed startup leaked process")
        }
        let sleeper = directory.appendingPathComponent("fake-core")
        try "#!/bin/sh\nexec /bin/sleep 20\n".write(to: sleeper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
        let pending = Task {
            try await engine.start(profile: profile, password: password, ports: ports, directory: directory, executable: sleeper)
        }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        do { try await pending.value; throw ClientError.message("Cancelled startup succeeded") }
        catch is CancellationError { }
        try check(!engine.isRunning, "Cancelled startup leaked process")
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("run-") }
        try check(remaining.isEmpty, "Runtime credentials not cleaned up")
        print("PASS: crash cleanup, restart, disconnect, startup failure, cancellation")
    }
}
