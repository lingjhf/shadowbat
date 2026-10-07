import Foundation
import Darwin

@MainActor
final class ProcessProxyEngine {
    let probeURL: String
    let probeInterval: String
    let testAPIPort: Int?
    private let tunAuthorizer: PrivilegedTunClient.Authorizer?
    private let tunConfiguration: (([String: Any]) -> [String: Any])?
    init(probeURL: String = "https://www.apple.com/library/test/success.html", probeInterval: String = "1m", testAPIPort: Int? = nil,
         tunAuthorizer: PrivilegedTunClient.Authorizer? = nil, tunConfiguration: (([String: Any]) -> [String: Any])? = nil) {
        self.probeURL = probeURL
        self.probeInterval = probeInterval
        self.testAPIPort = testAPIPort
        self.tunAuthorizer = tunAuthorizer
        self.tunConfiguration = tunConfiguration
    }
    var onLog: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var process: Process?
    private var pipe: Pipe?
    private var runDirectory: URL?
    private var secrets: [String] = []
    private var logBuffer = ""
    private var privileged: PrivilegedTunClient?
    private var shutdownTask: Task<Void, Never>?

    var isRunning: Bool { process?.isRunning == true }
    var isTunRunning: Bool { isRunning && privileged?.started == true }
    var actualCorePID: Int32? { privileged?.corePID ?? process?.processIdentifier }
    var supervisorPID: Int32? { privileged?.supervisorPID }

    func start(profile: ServerProfile, password: String, ports: LocalPorts, directory: URL,
               executable: URL? = nil, routing: [String: Any] = [:], tun: Bool = false, tunHelper: URL? = nil) async throws {
        try await start(servers: [ProxyServer(profile: profile, password: password)], ports: ports,
                        directory: directory, executable: executable, routing: routing, tun: tun, tunHelper: tunHelper)
    }

    func start(servers: [ProxyServer], ports: LocalPorts, directory: URL,
               executable: URL? = nil, routing: [String: Any] = [:], tun: Bool = false, tunHelper: URL? = nil) async throws {
        if let shutdownTask { await shutdownTask.value }
        guard process == nil else { throw ClientError.message("代理内核已启动。") }
        guard !servers.isEmpty else { throw ClientError.message("请添加或启用至少一个候选节点。") }
        for server in servers { try server.profile.validate(password: server.password) }
        try ports.validate()
        // A previous crashed app's watchdog may still be releasing its sockets.
        // Never stop an unknown listener; retry briefly, then report the conflict.
        try await Self.waitForAvailablePorts(ports, tun: tun)
        guard process == nil else { throw ClientError.message("代理内核已启动。") }
        guard let executable = executable ?? Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("sing-box"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ClientError.message("App 中缺少 sing-box，请运行 scripts/prepare-core.sh 后重新构建。")
        }
        var configuration = try SingBoxConfiguration.make(servers: servers, ports: ports, settings: routing,
                                                           probeURL: probeURL, interval: probeInterval, tun: tun)
        if tun, let tunConfiguration { configuration = tunConfiguration(configuration) }
        if let testAPIPort {
            configuration["experimental"] = ["clash_api": ["external_controller": "127.0.0.1:\(testAPIPort)"]]
        }
        let folder = directory.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        runDirectory = folder
        secrets = servers.flatMap { server in
            [server.password, Data(server.password.utf8).base64EncodedString(),
             Data("\(server.profile.method):\(server.password)".utf8).base64EncodedString()]
        }.sorted { $0.count > $1.count }
        do {
            let configURL = folder.appendingPathComponent("config.json")
            let data = try JSONSerialization.data(withJSONObject: configuration)
            guard FileManager.default.createFile(atPath: configURL.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw ClientError.message("无法创建内核配置。")
            }
            let output = Pipe()
            if tun {
                privileged = try PrivilegedTunClient(helper: tunHelper ?? executable.deletingLastPathComponent().appendingPathComponent("shadowbat-proxy-helper"), authorizer: tunAuthorizer)
                privileged?.onLog = { [weak self] in self?.receive($0) }
            }
            let child = privileged?.launcher ?? Process()
            if !tun {
                child.executableURL = executable
                child.arguments = ["run", "-c", configURL.path]
                child.standardInput = FileHandle.nullDevice
            }
            child.standardOutput = output
            child.standardError = output
            // A small watchdog prevents an orphaned proxy if the host app crashes.
            let parentPID = getpid()
            child.environment = ProcessInfo.processInfo.environment
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
                    guard let self, self.process === child, self.shutdownTask == nil else { return }
                    self.cleanup()
                    self.onExit?(status)
                }
            }
            pipe = output
            process = child
            try child.run()
            Self.startWatchdog(childPID: child.processIdentifier, parentPID: parentPID, directory: folder,
                               tunDirectory: privileged?.watchdogDirectory)
            if let privileged {
                onLog?("正在等待 macOS 管理员授权，以创建 TUN 隧道。")
                try await privileged.connect(configuration: configuration)
            }
            // Wait asynchronously for both local listeners to accept connections.
            for _ in 0..<300 {
                try Task.checkCancellation()
                guard child.isRunning else { throw ClientError.message("代理内核启动失败，请检查日志。") }
                if Self.socksReady(ports.socks), Self.canConnect(ports.http), !tun || privileged?.started == true {
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
        if let shutdownTask { await shutdownTask.value; return }
        guard let child = process else { cleanup(); return }
        // An unstructured task owns cleanup independently of a cancelled start.
        // Concurrent disconnects must all await the same actual process exit.
        let task = Task { @MainActor in
            await self.stopChild(child)
            self.shutdownTask = nil
        }
        shutdownTask = task
        await task.value
    }

    private func stopChild(_ child: Process) async {
        child.terminationHandler = nil
        let wasTun = privileged?.hasSession == true
        privileged?.closeControl()
        if wasTun && child.isRunning {
            for _ in 0..<160 {
                if !child.isRunning { break }
                await Self.cleanupPause()
            }
        }
        if child.isRunning {
            child.terminate()
            for _ in 0..<40 {
                if !child.isRunning { break }
                await Self.cleanupPause()
            }
            if child.isRunning {
                kill(child.processIdentifier, SIGKILL)
            }
        }
        if child.processIdentifier > 0 {
            // Reap off the UI thread before publishing "disconnected" or
            // allowing another core to bind the same ports.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    child.waitUntilExit()
                    continuation.resume()
                }
            }
        }
        cleanup()
    }

    private static func cleanupPause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
                continuation.resume()
            }
        }
    }

    private static func waitForAvailablePorts(_ ports: LocalPorts, tun: Bool) async throws {
        // The root TUN watchdog has a five-second graceful shutdown budget.
        let attempts = tun ? 160 : 60
        for attempt in 0...attempts {
            try Task.checkCancellation()
            do {
                for port in [ports.socks, ports.http] { try checkAvailable(port) }
                return
            } catch {
                if attempt == attempts { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func cleanup() {
        privileged?.closeControl()
        privileged = nil
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

    private static func startWatchdog(childPID: Int32, parentPID: Int32, directory: URL, tunDirectory: URL?) {
        // The detached watcher exits with either process; it has no credentials or config contents.
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Verify the unique configuration path before signalling, including
        // after the grace period, to avoid targeting a reused process ID.
        let script = """
        alive() {
          # A sudo launcher belongs to root: kill -0 returns EPERM while it is alive.
          # Keep the cheap signal probe for owned processes; ps handles EPERM.
          kill -0 "$1" 2>/dev/null || /bin/ps -p "$1" -o pid= >/dev/null 2>&1
        }
        owned() {
          alive "$2" || return 1
          case "$(/bin/ps -ww -p "$2" -o command=)" in
            *"$3/config.json"*) return 0 ;;
            *"$4/control.sock"*) [ -n "$4" ] ;;
            *) return 1 ;;
          esac
        }
        while alive "$1" && alive "$2"; do sleep 0.2; done
        if ! alive "$1" && owned "$@"; then
          kill -TERM "$2" 2>/dev/null
          count=0
          while owned "$@" && [ "$count" -lt 10 ]; do sleep 0.2; count=$((count + 1)); done
          if owned "$@"; then kill -KILL "$2" 2>/dev/null; fi
        fi
        /bin/rm -rf -- "$3"
        if [ -n "$4" ]; then /bin/rm -rf -- "$4"; fi
        """
        watcher.arguments = ["-c", script, "shadowbat-watchdog", String(parentPID), String(childPID), directory.path,
                             tunDirectory?.path ?? ""]
        watcher.standardInput = FileHandle.nullDevice
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        try? watcher.run()
    }
}

/// macOS native tray and Flutter share a direct-only policy and one core.
enum SingBoxConfiguration {
    static let reserved = ["127.0.0.0/8", "169.254.0.0/16", "::1/128", "fe80::/10"]
    static let privateNetworks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"]
    static func directSettings(_ value: [String: Any]) throws -> [String: Any] {
        let defaultAction = value["defaultAction"] as? String ?? "proxy"
        guard value["defaultAction"] == nil || value["defaultAction"] is String,
              ["direct", "proxy"].contains(defaultAction),
              let rules = value["rules"] as? [[String: Any]] ?? (value["rules"] == nil ? [] : nil), rules.count <= 1000 else {
            throw ClientError.message("直连配置无效，最多支持 1000 条目标。")
        }
        var ids = Set<String>()
        var direct: [[String: Any]] = []
        for rule in rules {
            guard let id = rule["id"] as? String, !id.isEmpty, id.count <= 100, ids.insert(id).inserted,
                  let type = rule["type"] as? String, ["domain", "suffix", "ip", "cidr"].contains(type),
                  let raw = rule["target"] as? String,
                  let action = rule["action"] as? String, ["direct", "proxy"].contains(action),
                  rule["enabled"] == nil || rule["enabled"] is Bool else { throw ClientError.message("直连目标信息不完整。") }
            var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch type {
            case "domain", "suffix":
                target = target.lowercased()
                if target.hasSuffix(".") { target.removeLast() }
                guard !target.isEmpty, target.count <= 253, !isIP(target),
                      target.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                        $0.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil
                      }) else { throw ClientError.message("请填写有效域名，不含协议、路径或通配符。") }
            case "ip":
                guard isIP(target) else { throw ClientError.message("请填写有效 IPv4 或 IPv6 地址。") }
            default:
                let parts = target.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, isIP(String(parts[0])),
                      parts[1].range(of: "^[0-9]{1,3}$", options: .regularExpression) != nil, let bits = Int(parts[1]), bits >= 0,
                      bits <= (parts[0].contains(":") ? 128 : 32) else { throw ClientError.message("请填写有效 IP 网段。") }
            }
            if action == "direct" {
                direct.append(["id": id, "type": type, "target": target, "action": "direct", "enabled": rule["enabled"] as? Bool ?? true])
            }
        }
        return ["defaultAction": "proxy", "rules": direct]
    }
    private static func isIP(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    static func make(servers: [ProxyServer], ports: LocalPorts, settings: [String: Any],
                     probeURL: String, interval: String, tun: Bool = false) throws -> [String: Any] {
        guard !servers.isEmpty else { throw ClientError.message("请添加至少一个节点。") }
        let rules = (try directSettings(settings)["rules"] as! [[String: Any]]).filter { $0["enabled"] as? Bool == true }
        var route: [[String: Any]] = tun ? [["action": "sniff"], ["protocol": "dns", "action": "hijack-dns"]] : []
        route.append(["ip_cidr": reserved, "action": "route", "outbound": "direct"])
        var dnsRules: [[String: Any]] = []
        var resolved = false
        for rule in rules {
            let type = rule["type"] as! String, target = rule["target"] as! String
            if !resolved && ["ip", "cidr"].contains(type) { route.append(["action": "resolve"]); resolved = true }
            let match: [String: Any]
            switch type {
            case "domain": match = ["domain": [target]]
            case "suffix": match = ["domain_suffix": [target]]
            case "ip": match = ["ip_cidr": [target + (target.contains(":") ? "/128" : "/32")]]
            default: match = ["ip_cidr": [target]]
            }
            route.append(match.merging(["action": "route", "outbound": "direct"]) { _, new in new })
            if ["domain", "suffix"].contains(type) {
                dnsRules.append(match.merging(["action": "route", "server": "bootstrap"]) { _, new in new })
            }
        }
        if !resolved { route.append(["action": "resolve"]) }
        route.append(["ip_cidr": privateNetworks, "action": "route", "outbound": "direct"])
        let tags = servers.map { "node-\($0.profile.id.uuidString)" }
        var outbounds: [[String: Any]] = [["type": "direct", "tag": "direct"]]
        if servers.count > 1 {
            outbounds.append(["type": "urltest", "tag": "proxy", "outbounds": tags, "url": probeURL, "interval": interval,
                              "tolerance": 50, "interrupt_exist_connections": false])
        } else { outbounds.append(["type": "selector", "tag": "proxy", "outbounds": tags]) }
        outbounds += servers.map { ["type": "shadowsocks", "tag": "node-\($0.profile.id.uuidString)",
                                    "server": $0.profile.host, "server_port": $0.profile.port,
                                    "method": $0.profile.method, "password": $0.password] }
        var inbounds: [[String: Any]] = [["type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": ports.socks],
                                       ["type": "http", "tag": "http-in", "listen": "127.0.0.1", "listen_port": ports.http]]
        if tun {
            inbounds.append(["type": "tun", "tag": "tun-in", "address": ["172.29.254.1/30", "fdfe:29:fffe::1/126"], "mtu": 1500,
                             "auto_route": true, "route_exclude_address": reserved, "stack": "system", "dns_mode": "hijack"])
        }
        return ["log": ["level": "info", "timestamp": true],
                "dns": ["reverse_mapping": true, "servers": [["type": "local", "tag": "bootstrap"],
                        ["type": "https", "tag": "remote-dns", "server": "1.1.1.1", "detour": "proxy"]],
                        "rules": dnsRules, "final": "remote-dns", "strategy": "prefer_ipv4"],
                "route": ["auto_detect_interface": true, "default_domain_resolver": "bootstrap", "rules": route, "final": "proxy"],
                "inbounds": inbounds,
                "outbounds": outbounds]
    }
}
