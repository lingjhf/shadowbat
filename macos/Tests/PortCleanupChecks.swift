import Darwin
import Foundation

@main
@MainActor
enum PortCleanupChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ClientError.message(message) }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count == 6, let socks = Int(args[2]), let http = Int(args[3]) else {
            throw ClientError.message("Invalid port cleanup fixture arguments")
        }
        let core = URL(fileURLWithPath: args[1]), directory = URL(fileURLWithPath: args[4])
        let ports = LocalPorts(socks: socks, http: http)
        let profile = ServerProfile(name: "Port cleanup fixture", host: "127.0.0.1", port: 65534, method: "aes-256-gcm")
        if args[5] == "--pending-host" {
            let pending = ProcessProxyEngine(tunAuthorizer: { _, socketPath in
                let child = Process()
                child.executableURL = core
                child.arguments = [socketPath]
                return child
            })
            Task {
                try await pending.start(profile: profile, password: "temporary-cleanup-fixture", ports: ports,
                                        directory: directory, executable: core, tun: true)
            }
            for _ in 0..<100 {
                if let pid = pending.actualCorePID, pending.isRunning {
                    print("READY: \(pid)")
                    while true { try await Task.sleep(for: .seconds(1)) }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw ClientError.message("Pending authorization did not start")
        }
        let engine = ProcessProxyEngine()
        if args[5] == "--occupied" {
            do {
                try await engine.start(profile: profile, password: "temporary-cleanup-fixture", ports: ports,
                                       directory: directory, executable: core)
            } catch {
                try require(error.localizedDescription.contains("已被占用") && engine.process == nil,
                            "Unknown listener was not reported as a port conflict")
                print("PASS: another application's listener is preserved")
                return
            }
            await engine.stop()
            throw ClientError.message("An occupied port unexpectedly started")
        }
        if args[5] == "--host" {
            try await engine.start(profile: profile, password: "temporary-cleanup-fixture", ports: ports,
                                   directory: directory, executable: core)
            print("READY: \(engine.actualCorePID!)")
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        for index in 0..<20 {
            try await engine.start(profile: profile, password: "temporary-cleanup-fixture", ports: ports,
                                   directory: directory, executable: core)
            guard let child = engine.process else { throw ClientError.message("Missing fixture core") }
            let stopping = Task { await engine.stop() }
            let secondStop = Task { await engine.stop() }
            stopping.cancel()
            await stopping.value
            await secondStop.value
            let returnedBeforeExit = child.isRunning
            // Ensure a failing regression test also reaps its isolated child.
            if returnedBeforeExit {
                kill(child.processIdentifier, SIGKILL)
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { child.waitUntilExit(); continuation.resume() }
                }
            }
            try require(!returnedBeforeExit, "Cancelled shutdown returned before the core actually exited")
            try require(child.terminationReason == .exit && child.terminationStatus == 0,
                        "Cancelling the caller skipped graceful core shutdown")
            try ProcessProxyEngine.checkAvailable(socks)
            try ProcessProxyEngine.checkAvailable(http)
            print("PASS: cancelled shutdown and immediate port reuse, cycle \(index + 1)")
        }
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("run-") }
        try require(remaining.isEmpty, "Runtime credentials remained after shutdown")
    }
}
