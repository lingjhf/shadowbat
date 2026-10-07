import Darwin
import Foundation

/// Runs the application's actual native engine and production helper, with scoped fixture routes.
@main
@MainActor
enum TunAppChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try value()) { throw TunWire.error(message) }
    }
    static func command(_ args: [String], allowFailure: Bool = false) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: args[0]); process.arguments = Array(args.dropFirst())
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(allowFailure || process.terminationStatus == 0, "Command failed: \(String(decoding: data, as: UTF8.self))")
        return String(decoding: data, as: UTF8.self)
    }
    static func udp(_ target: String, port: Int, payload: [UInt8]) throws -> [UInt8] {
        let ipv6 = target.contains(":")
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TunWire.error("UDP fixture socket failed") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = UInt16(port).bigEndian; endpoint.sin_addr.s_addr = inet_addr(target)
        let sent: Int
        if ipv6 {
            var v6 = sockaddr_in6(); v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6); v6.sin6_port = UInt16(port).bigEndian
            _ = target.withCString { inet_pton(AF_INET6, $0, &v6.sin6_addr) }
            sent = withUnsafePointer(to: &v6) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    payload.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, address, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            }
        } else {
            sent = withUnsafePointer(to: &endpoint) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    payload.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }
        try require(sent == payload.count, "UDP request failed")
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &bytes, bytes.count, 0)
        try require(count > 0, "UDP fixture response timed out")
        return Array(bytes.prefix(count))
    }
    static func authorizedKill(_ pid: Int32) async throws {
        let process = Process()
        if ProcessInfo.processInfo.environment["SHADOWBAT_TUN_TEST_SUDO"] == "1" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "/bin/kill", "-KILL", String(pid)]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"/bin/kill -KILL \(pid)\" with administrator privileges"]
        }
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try require(process.terminationStatus == 0, "Isolated crash injection authorization failed")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count == 9, let ssPort = Int(args[3]), let directPort = Int(args[4]),
              let socks = Int(args[5]), let http = Int(args[6]) else { throw TunWire.error("Invalid fixture arguments") }
        let mode = args[1], core = URL(fileURLWithPath: args[2]), helper = URL(fileURLWithPath: args[7])
        let directory = URL(fileURLWithPath: args[8])
        let beforeDefault = try command(["/sbin/route", "-n", "get", "default"])
        let beforeDefault6 = try command(["/sbin/route", "-n", "get", "-inet6", "default"], allowFailure: true)
        let beforeDNS = try command(["/usr/sbin/scutil", "--dns"])
        let beforeProxy = try command(["/usr/sbin/scutil", "--proxy"])
        let profile = ServerProfile(name: "Isolated native TUN", host: "127.0.0.1", port: ssPort, method: "aes-256-gcm")
        let policy: [String: Any] = ["rules": [["id": "direct", "type": "ip", "target": "198.18.0.124", "action": "direct"],
                                             ["id": "direct-v6", "type": "ip", "target": "2001:db8::124", "action": "direct"]]]
        let authorizer: PrivilegedTunClient.Authorizer? = ProcessInfo.processInfo.environment["SHADOWBAT_TUN_TEST_SUDO"] == "1" ? { helper, path in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", helper.path, "--tun-session", path]
            return process
        } : nil
        let engine = ProcessProxyEngine(tunAuthorizer: authorizer, tunConfiguration: { source in
            var config = source
            var inbounds = config["inbounds"] as! [[String: Any]]
            for i in inbounds.indices where inbounds[i]["type"] as? String == "tun" {
                inbounds[i]["route_address"] = ["198.18.0.123/32", "198.18.0.124/32", "2001:db8::123/128", "2001:db8::124/128"]
                inbounds[i]["dns_mode"] = "disabled"
                inbounds[i]["interface_name"] = "utun64"
            }
            config["inbounds"] = inbounds
            var route = config["route"] as! [String: Any]
            route["auto_detect_interface"] = false
            var rules = route["rules"] as! [[String: Any]]
            for i in rules.indices where [["198.18.0.124/32"], ["2001:db8::124/128"]].contains(rules[i]["ip_cidr"] as? [String] ?? []) {
                rules[i]["override_address"] = "127.0.0.1"; rules[i]["override_port"] = directPort
            }
            route["rules"] = rules; config["route"] = route
            var dns = config["dns"] as! [String: Any]; dns["final"] = "bootstrap"; config["dns"] = dns
            return config
        })
        var exitStatus: Int32?, logs = ""
        engine.onExit = { exitStatus = $0 }
        engine.onLog = { logs += $0 + "\n" }
        do {
            try await engine.start(profile: profile, password: "temporary-tun-fixture-password", ports: LocalPorts(socks: socks, http: http),
                                   directory: directory, executable: core, routing: policy, tun: true, tunHelper: helper)
            try require(engine.isTunRunning, "TUN readiness was not published")
            for (target, marker) in [("198.18.0.123", "shadowbat-tun-proxy"), ("198.18.0.124", "shadowbat-tun-direct"),
                                     ("2001:db8::123", "shadowbat-tun-proxy"), ("2001:db8::124", "shadowbat-tun-direct")] {
                let host = target.contains(":") ? "[\(target)]" : target
                let text = try command(["/usr/bin/curl", "--silent", "--show-error", "--fail", "--noproxy", "*", "--max-time", "5", "http://\(host):18080/"])
                try require(text == marker, "Native TUN selected wrong TCP path")
                let bytes = try udp(target, port: 18080, payload: Array("fixture-udp".utf8))
                try require(String(decoding: bytes, as: UTF8.self) == marker, "Native TUN selected wrong UDP path")
            }
            let dnsPacket: [UInt8] = [0x51,0x23,1,0,0,1,0,0,0,0,0,0,9] + Array("localhost".utf8) + [0,0,1,0,1]
            let answer = try udp("198.18.0.123", port: 53, payload: dnsPacket)
            try require(answer.count > 12 && answer[0...1] == dnsPacket[0...1] && answer[3] & 15 == 0 && answer.suffix(4) == [127,0,0,1], "TUN DNS hijack did not resolve localhost")
            try require(!logs.contains("temporary-tun-fixture-password"), "Privileged logs leaked credentials")
            print("PASS: app native TUN readiness, TCP, UDP, DNS and direct/proxy routing")
            if mode == "app-crash" {
                print("Injecting isolated app crash")
                kill(getpid(), SIGKILL)
            } else if mode == "core-crash" || mode == "supervisor-crash" {
                guard let pid = mode == "core-crash" ? engine.actualCorePID : engine.supervisorPID else { throw TunWire.error("Missing elevated PID") }
                try await authorizedKill(pid)
                for _ in 0..<200 {
                    if exitStatus != nil { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try require(exitStatus != nil && !engine.isRunning, "Unexpected privileged exit was not handled")
            } else {
                let corePID = engine.actualCorePID
                if mode == "cancelled-disconnect" {
                    let stopping = Task { await engine.stop() }
                    stopping.cancel()
                    await stopping.value
                } else { await engine.stop() }
                try require(!engine.isRunning && !engine.isTunRunning, "Native disconnect left TUN active")
                if let corePID {
                    try require(kill(corePID, 0) != 0 && errno == ESRCH, "Root-owned core survived disconnect")
                }
                try ProcessProxyEngine.checkAvailable(socks)
                try ProcessProxyEngine.checkAvailable(http)
                if mode == "cancelled-disconnect" {
                    try await engine.start(profile: profile, password: "temporary-tun-fixture-password",
                                           ports: LocalPorts(socks: socks, http: http), directory: directory,
                                           executable: core, routing: policy, tun: true, tunHelper: helper)
                    try require(engine.isTunRunning, "Immediate TUN reconnection failed")
                    await engine.stop()
                    try ProcessProxyEngine.checkAvailable(socks)
                    try ProcessProxyEngine.checkAvailable(http)
                    print("PASS: cancelled TUN shutdown releases the actual root core and reconnects immediately")
                }
            }
            for _ in 0..<100 {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig"); p.arguments = ["utun64"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try p.run(); p.waitUntilExit()
                if p.terminationStatus != 0 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(try command(["/sbin/route", "-n", "get", "default"]) == beforeDefault, "Default route changed")
            try require(try command(["/sbin/route", "-n", "get", "-inet6", "default"], allowFailure: true) == beforeDefault6, "IPv6 default route changed")
            try require(try command(["/usr/sbin/scutil", "--dns"]) == beforeDNS, "System DNS changed")
            try require(try command(["/usr/sbin/scutil", "--proxy"]) == beforeProxy, "System proxy changed")
            for target in ["198.18.0.123", "198.18.0.124"] {
                let route = try command(["/sbin/route", "-n", "get", target])
                try require(!route.contains("interface: utun64"), "Native TUN left a route behind")
            }
            try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("run-") }.isEmpty, "Credentials remained after native shutdown")
            print("PASS: \(mode) cleanup, routes, DNS, system proxy and runtime credentials")
        } catch {
            await engine.stop()
            FileHandle.standardError.write(Data(logs.utf8))
            throw error
        }
    }
}
