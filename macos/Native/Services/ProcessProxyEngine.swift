import Foundation
import Darwin

@MainActor
final class ProcessProxyEngine {
    var onLog: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var process: Process?
    private var pipe: Pipe?
    private var runDirectory: URL?
    private var secrets: [String] = []
    private var logBuffer = ""

    var isRunning: Bool { process?.isRunning == true }

    func start(profile: ServerProfile, password: String, ports: LocalPorts, directory: URL,
               executable: URL? = nil) async throws {
        try await start(servers: [ProxyServer(profile: profile, password: password)], ports: ports,
                        directory: directory, executable: executable)
    }

    func start(servers: [ProxyServer], ports: LocalPorts, directory: URL,
               executable: URL? = nil) async throws {
        guard process == nil else { throw ClientError.message("代理内核已启动。") }
        guard !servers.isEmpty else { throw ClientError.message("请添加或启用至少一个候选节点。") }
        for server in servers { try server.profile.validate(password: server.password) }
        try ports.validate()
        for port in [ports.socks, ports.http] { try Self.checkAvailable(port) }
        guard let executable = executable ?? Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("sslocal"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ClientError.message("App 中缺少 sslocal，请运行 scripts/prepare-core.sh 后重新构建。")
        }
        let folder = directory.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        runDirectory = folder
        secrets = servers.flatMap { server in
            [server.password, Data(server.password.utf8).base64EncodedString(),
             Data("\(server.profile.method):\(server.password)".utf8).base64EncodedString()]
        }.sorted { $0.count > $1.count }
        let configuration: [String: Any] = [
            "servers": servers.map { server in
                ["server": server.profile.host, "server_port": server.profile.port,
                 "method": server.profile.method, "password": server.password, "mode": "tcp_and_udp"] as [String: Any]
            },
            "balancer": ["max_server_rtt": 5, "check_interval": 10, "check_best_interval": 5],
            "locals": [
                ["local_address": "127.0.0.1", "local_port": ports.socks, "protocol": "socks", "mode": "tcp_and_udp"],
                ["local_address": "127.0.0.1", "local_port": ports.http, "protocol": "http", "mode": "tcp_only"]
            ]
        ]
        do {
            let configURL = folder.appendingPathComponent("config.json")
            let data = try JSONSerialization.data(withJSONObject: configuration)
            guard FileManager.default.createFile(atPath: configURL.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw ClientError.message("无法创建内核配置。")
            }
            let output = Pipe()
            let child = Process()
            child.executableURL = executable
            child.arguments = ["-c", configURL.path, "--log-without-time", "-vv"]
            child.standardOutput = output
            child.standardError = output
            child.standardInput = FileHandle.nullDevice
            // A small watchdog prevents an orphaned proxy if the host app crashes.
            let parentPID = getpid()
            child.environment = ProcessInfo.processInfo.environment
            // Keep node-selection events visible at the app's chosen log level.
            child.environment?.removeValue(forKey: "RUST_LOG")
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in
                    guard let self, self.process === child else { return }
                    self.receive(chunk)
                }
            }
            child.terminationHandler = { [weak self] child in
                let status = child.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self, self.process === child else { return }
                    self.cleanup()
                    self.onExit?(status)
                }
            }
            pipe = output
            process = child
            try child.run()
            Self.startWatchdog(childPID: child.processIdentifier, parentPID: parentPID, directory: folder)
            // Initial probes run before listeners start when there are multiple nodes.
            for _ in 0..<300 {
                try Task.checkCancellation()
                guard child.isRunning else { throw ClientError.message("代理内核启动失败，请检查日志。") }
                if Self.socksReady(ports.socks), Self.canConnect(ports.http) {
                    onLog?("本地监听已就绪：SOCKS5 \(ports.socks)，HTTP \(ports.http)。")
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ClientError.message("等待代理内核启动超时。")
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        guard let child = process else { cleanup(); return }
        child.terminationHandler = nil
        if child.isRunning {
            child.terminate()
            for _ in 0..<40 {
                if !child.isRunning { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                for _ in 0..<20 {
                    if !child.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        cleanup()
    }

    private func cleanup() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if !logBuffer.isEmpty { emit(logBuffer) }
        logBuffer = ""
        process = nil
        pipe = nil
        if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
        runDirectory = nil
        secrets = []
    }

    private func receive(_ chunk: String) {
        logBuffer += chunk
        while let newline = logBuffer.firstIndex(of: "\n") {
            emit(String(logBuffer[..<newline]))
            logBuffer.removeSubrange(...newline)
        }
        if logBuffer.count > 8192 { emit(logBuffer); logBuffer = "" }
    }

    private func emit(_ text: String) {
        var text = text
        for secret in secrets where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "[已隐藏]") }
        if text.lowercased().contains("password") { text = "内核日志含密码字段，已隐藏。" }
        if !text.isEmpty { onLog?(String(text.prefix(2000))) }
    }

    private static func address(_ port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    static func checkAvailable(_ port: Int) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.message("无法创建本地网络套接字。") }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var endpoint = address(port)
        let result = withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 1) == 0 else {
            throw ClientError.message("本地端口 \(port) 已被占用，请修改端口或关闭其他代理。")
        }
    }

    private static func connectedSocket(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var endpoint = address(port)
        let result = withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    private static func canConnect(_ port: Int) -> Bool {
        guard let fd = connectedSocket(port) else { return false }
        close(fd)
        return true
    }

    private static func socksReady(_ port: Int) -> Bool {
        guard let fd = connectedSocket(port) else { return false }
        defer { close(fd) }
        let greeting: [UInt8] = [5, 1, 0]
        guard greeting.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == 3 else { return false }
        var reply = [UInt8](repeating: 0, count: 2)
        let count = reply.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, MSG_WAITALL) }
        return count == 2 && reply == [5, 0]
    }

    private static func startWatchdog(childPID: Int32, parentPID: Int32, directory: URL) {
        // The detached watcher exits with either process; it has no credentials or config contents.
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null && kill -0 \"$2\" 2>/dev/null; do sleep 1; done; if ! kill -0 \"$1\" 2>/dev/null; then kill -TERM \"$2\" 2>/dev/null; /bin/rm -rf -- \"$3\"; fi", "shadowbat-watchdog", String(parentPID), String(childPID), directory.path]
        watcher.standardInput = FileHandle.nullDevice
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        try? watcher.run()
    }
}
