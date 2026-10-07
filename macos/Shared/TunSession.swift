import Darwin
import Foundation
import Security

/// Bounded JSON messages over a private, per-connection Unix socket. No TCP control port.
nonisolated enum TunWire {
    static func error(_ text: String) -> NSError {
        NSError(domain: "com.lingj.shadowbat.tun", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw error("TUN 控制路径过长。") }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func configure(_ fd: Int32, nonblocking: Bool = false) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        if nonblocking { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }
    static func send(_ value: [String: Any], to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard count > 0 else { throw error("TUN 控制连接已关闭。") }
            offset += count
        }
    }
    static func peerUID(_ fd: Int32) throws -> uid_t {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { throw error("无法验证 TUN 控制连接。") }
        return uid
    }
}

/// The root process accepts only network configuration emitted by the native backend.
/// File output, services, plugins, scripts, external includes and arbitrary listeners are rejected.
nonisolated enum TunConfigurationValidator {
    static func keys(_ value: [String: Any], _ allowed: [String]) throws {
        guard Set(value.keys).isSubset(of: Set(allowed)) else { throw TunWire.error("TUN 配置包含不支持的字段。") }
    }
    static func validate(_ config: [String: Any]) throws {
        try keys(config, ["log", "dns", "route", "inbounds", "outbounds"])
        guard let log = config["log"] as? [String: Any], let dns = config["dns"] as? [String: Any],
              let route = config["route"] as? [String: Any], let inbounds = config["inbounds"] as? [[String: Any]],
              let outbounds = config["outbounds"] as? [[String: Any]], inbounds.count == 3,
              outbounds.count >= 3, outbounds.count <= 1002 else { throw TunWire.error("TUN 配置不完整。") }
        try keys(log, ["level", "timestamp"])
        try keys(dns, ["reverse_mapping", "servers", "rules", "final", "strategy"])
        for server in dns["servers"] as? [[String: Any]] ?? [] {
            try keys(server, ["type", "tag", "server", "detour"])
            guard ["local", "https"].contains(server["type"] as? String ?? "") else { throw TunWire.error("不支持的 DNS 配置。") }
        }
        for rule in dns["rules"] as? [[String: Any]] ?? [] { try keys(rule, ["domain", "domain_suffix", "action", "server"]) }
        try keys(route, ["auto_detect_interface", "default_domain_resolver", "rules", "final"])
        guard route["final"] as? String == "proxy", let rules = route["rules"] as? [[String: Any]], rules.count <= 1005 else {
            throw TunWire.error("TUN 路由配置无效。")
        }
        for rule in rules {
            try keys(rule, ["action", "outbound", "protocol", "ip_cidr", "domain", "domain_suffix", "override_address", "override_port"])
            guard ["sniff", "hijack-dns", "resolve", "route"].contains(rule["action"] as? String ?? "") else { throw TunWire.error("不支持的 TUN 路由。") }
        }
        var types = Set<String>(), ports = Set<Int>()
        for inbound in inbounds {
            guard let type = inbound["type"] as? String, types.insert(type).inserted else { throw TunWire.error("TUN 监听器重复。") }
            if type == "tun" {
                try keys(inbound, ["type", "tag", "address", "mtu", "auto_route", "route_exclude_address", "route_address", "stack", "dns_mode", "interface_name"])
                guard inbound["address"] as? [String] == ["172.29.254.1/30", "fdfe:29:fffe::1/126"], inbound["auto_route"] as? Bool == true,
                      inbound["stack"] as? String == "system", ["hijack", "disabled"].contains(inbound["dns_mode"] as? String ?? ""),
                      inbound["route_exclude_address"] as? [String] == ["127.0.0.0/8", "169.254.0.0/16", "::1/128", "fe80::/10"] else {
                    throw TunWire.error("TUN 网卡配置无效。")
                }
                if let name = inbound["interface_name"] as? String, name.range(of: "^utun[0-9]{1,4}$", options: .regularExpression) == nil {
                    throw TunWire.error("TUN 网卡名称无效。")
                }
            } else {
                try keys(inbound, ["type", "tag", "listen", "listen_port"])
                guard ["socks", "http"].contains(type), inbound["listen"] as? String == "127.0.0.1",
                      let port = inbound["listen_port"] as? Int, (1024...65535).contains(port), ports.insert(port).inserted else {
                    throw TunWire.error("本地代理只能监听回环地址。")
                }
            }
        }
        guard types == Set(["tun", "socks", "http"]) else { throw TunWire.error("TUN 监听器不完整。") }
        for outbound in outbounds {
            switch outbound["type"] as? String {
            case "direct": try keys(outbound, ["type", "tag"])
            case "shadowsocks": try keys(outbound, ["type", "tag", "server", "server_port", "method", "password"])
            case "selector": try keys(outbound, ["type", "tag", "outbounds"])
            case "urltest": try keys(outbound, ["type", "tag", "outbounds", "url", "interval", "tolerance", "interrupt_exist_connections"])
            default: throw TunWire.error("不支持的 TUN 出口。")
            }
        }
    }
}

/// Per-connection privileged supervisor. The installed XPC helper's signing policy is unchanged.
nonisolated enum TunSessionSupervisor {
    static func run(socketPath: String, coreURL: URL) throws {
        signal(SIGPIPE, SIG_IGN)
        guard geteuid() == 0 else { throw TunWire.error("TUN 需要 macOS 管理员授权。") }
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        var metadata = stat()
        guard directory.deletingLastPathComponent().path == "/private/tmp",
              directory.lastPathComponent.range(of: "^shadowbat-tun-[a-f0-9]{16}$", options: .regularExpression) != nil,
              lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700, socketPath == directory.appendingPathComponent("control.sock").path,
              metadata.st_uid != 0 else { throw TunWire.error("TUN 控制目录无效。") }
        let uid = metadata.st_uid
        let controlDirectoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard controlDirectoryFD >= 0 else { throw TunWire.error("无法打开 TUN 控制目录。") }
        var openedDirectory = stat()
        guard fstat(controlDirectoryFD, &openedDirectory) == 0, openedDirectory.st_dev == metadata.st_dev,
              openedDirectory.st_ino == metadata.st_ino else {
            close(controlDirectoryFD)
            throw TunWire.error("TUN 控制目录已改变。")
        }
        // Remove only the socket in the directory we opened, even if its pathname is renamed.
        // Never recursively remove a user-writable directory with root privileges.
        defer {
            _ = unlinkat(controlDirectoryFD, "control.sock", 0)
            close(controlDirectoryFD)
            _ = rmdir(directory.path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TunWire.error("无法创建 TUN 控制连接。") }
        defer { close(fd) }
        TunWire.configure(fd)
        var address = try TunWire.address(socketPath)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0, try TunWire.peerUID(fd) == uid else { throw TunWire.error("TUN 控制连接身份不匹配。") }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data(), byte: UInt8 = 0
        while recv(fd, &byte, 1, 0) == 1 && byte != 10 {
            request.append(byte)
            guard request.count <= 1_048_576 else { throw TunWire.error("TUN 配置过大。") }
        }
        guard byte == 10, let config = try JSONSerialization.jsonObject(with: request) as? [String: Any] else { throw TunWire.error("TUN 配置传输失败。") }
        try TunConfigurationValidator.validate(config)
        let lock = open("/private/var/run/com.lingj.shadowbat.tun.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw TunWire.error("无法获取 TUN 运行锁。") }
        defer { close(lock) }
        guard fstat(lock, &metadata) == 0, metadata.st_uid == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0 else { throw TunWire.error("TUN 运行锁权限无效。") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw TunWire.error("另一份 Shadowbat 正在使用 TUN，请先断开。") }
        var template = Array("/private/tmp/shadowbat-root-tun-XXXXXXXX".utf8) + [0]
        let rootDirectory = try template.withUnsafeMutableBufferPointer { buffer -> URL in
            guard let path = mkdtemp(buffer.baseAddress!) else { throw TunWire.error("无法创建 TUN 运行目录。") }
            return URL(fileURLWithPath: String(cString: path))
        }
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        guard lstat(coreURL.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o022 == 0 else { throw TunWire.error("内核文件权限无效。") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(coreURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw TunWire.error("sing-box 签名校验失败，请重新构建应用。")
        }
        // Root owns immutable copies throughout the elevated session, including temporary files.
        let coreCopy = rootDirectory.appendingPathComponent("sing-box")
        try FileManager.default.copyItem(at: coreURL, to: coreCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: coreCopy.path)
        var copiedCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(coreCopy as CFURL, [], &copiedCode) == errSecSuccess, let copiedCode,
              SecStaticCodeCheckValidity(copiedCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw TunWire.error("TUN 内核副本签名无效。")
        }
        let configURL = rootDirectory.appendingPathComponent("config.json")
        guard FileManager.default.createFile(atPath: configURL.path, contents: request, attributes: [.posixPermissions: 0o600]) else {
            throw TunWire.error("无法创建 TUN 配置。")
        }
        let output = Pipe(), child = Process()
        child.executableURL = coreCopy
        child.arguments = ["run", "-c", configURL.path]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": rootDirectory.path, "TMPDIR": rootDirectory.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let watchdogPipe = Pipe(), watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "exec 3>&1; exec 1>/dev/null; IFS= read -r done; [ \"$done\" = finished ] && exit 0; same_core() { exe=$(/bin/ps -ww -p \"$1\" -o comm=); [ \"$exe\" = \"$2/sing-box\" ] || [ \"$exe\" = \"${2#/private}/sing-box\" ]; }; same_core \"$1\" \"$2\" && kill -TERM \"$1\" 2>/dev/null; i=0; while same_core \"$1\" \"$2\" && [ \"$i\" -lt 50 ]; do sleep .1; i=$((i+1)); done; same_core \"$1\" \"$2\" && kill -KILL \"$1\" 2>/dev/null; /bin/rm -rf -- \"$2\"", "shadowbat-tun-watchdog", String(child.processIdentifier), rootDirectory.path]
        watchdog.standardInput = watchdogPipe
        // Keep the lease locked while the watchdog cleans up a crashed supervisor.
        let watchdogLock = FileHandle(fileDescriptor: dup(lock), closeOnDealloc: true)
        watchdog.standardOutput = watchdogLock
        watchdog.standardError = FileHandle.nullDevice
        defer {
            stop(child)
            try? watchdogPipe.fileHandleForWriting.write(contentsOf: Data("finished\n".utf8))
            try? watchdogPipe.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        try watchdog.run()
        try watchdogLock.close()
        try watchdogPipe.fileHandleForReading.close()
        let flag = StopFlag()
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { flag.set() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        try TunWire.send(["event": "started", "corePID": child.processIdentifier, "supervisorPID": getpid()], to: fd)
        var buffer = [UInt8](repeating: 0, count: 8192)
        let logFD = output.fileHandleForReading.fileDescriptor
        while child.isRunning && !flag.isSet {
            var descriptors = [pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0), pollfd(fd: logFD, events: Int16(POLLIN), revents: 0)]
            guard poll(&descriptors, 2, 250) >= 0 || errno == EINTR else { break }
            if descriptors[0].revents != 0 {
                // EOF, a stop message, or malformed control input all end the privileged lease.
                _ = recv(fd, &buffer, buffer.count, 0)
                break
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 {
                let count = read(logFD, &buffer, buffer.count)
                if count > 0 { try TunWire.send(["event": "log", "text": String(decoding: buffer.prefix(count), as: UTF8.self)], to: fd) }
            }
        }
        let unexpectedExit = !child.isRunning && !flag.isSet
        stop(child)
        try? TunWire.send(["event": "exit", "status": child.terminationStatus], to: fd)
        if unexpectedExit { throw TunWire.error("TUN 内核意外退出（\(child.terminationStatus)）。") }
    }
    private static func stop(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        for _ in 0..<50 {
            if !child.isRunning { return }
            usleep(100_000)
        }
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
    }
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func set() { lock.lock(); stopped = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }
}
