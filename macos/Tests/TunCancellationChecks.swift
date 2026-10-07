import Foundation

@MainActor
enum TunCancellationChecks {
    static func run(profile: ServerProfile, password: String, ports: LocalPorts, directory: URL, executable: URL) async throws {
        let declined = ProcessProxyEngine(tunAuthorizer: { _, _ in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/false"); return process
        })
        do {
            try await declined.start(profile: profile, password: password, ports: ports, directory: directory, executable: executable, tun: true)
            throw ClientError.message("Declined TUN authorization unexpectedly succeeded")
        } catch {
            try SmokeChecks.check(!declined.isRunning, "Declined authorization left a launcher running")
        }
        let pending = ProcessProxyEngine(tunAuthorizer: { _, _ in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]; return process
        })
        let start = Task { try await pending.start(profile: profile, password: password, ports: ports, directory: directory, executable: executable, tun: true) }
        for _ in 0..<20 {
            if pending.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let time = Date()
        start.cancel()
        _ = await start.result
        try SmokeChecks.check(Date().timeIntervalSince(time) < 2 && !pending.isRunning, "Cancelling pending authorization blocked shutdown")
        try ProcessProxyEngine.checkAvailable(ports.socks); try ProcessProxyEngine.checkAvailable(ports.http)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try SmokeChecks.check(!files.contains { $0.hasPrefix("run-") }, "Pending TUN credentials were not cleaned up")
        print("PASS: declined TUN authorization and responsive cancellation leave no process, listeners or credentials")
    }
}
