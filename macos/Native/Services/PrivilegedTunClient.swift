import Darwin
import Foundation

@MainActor
final class PrivilegedTunClient {
    typealias Authorizer = (URL, String) throws -> Process
    let launcher: Process
    private let directory: URL
    private var listener: Int32 = -1
    private var connection: Int32 = -1
    private var reader: DispatchSourceRead?
    private var buffer = Data()
    private(set) var started = false
    private(set) var corePID: Int32?
    private(set) var supervisorPID: Int32?
    var hasSession: Bool { connection >= 0 || started }
    var watchdogDirectory: URL { directory }
    var onLog: ((String) -> Void)?

    init(helper: URL, authorizer: Authorizer? = nil) throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        directory = URL(fileURLWithPath: "/private/tmp/shadowbat-tun-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("control.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        listener = fd
        do {
            guard fd >= 0 else { throw TunWire.error("无法创建 TUN 控制连接。") }
            TunWire.configure(fd, nonblocking: true)
            var address = try TunWire.address(path)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0, listen(fd, 1) == 0 else { throw TunWire.error("无法监听 TUN 控制连接。") }
            launcher = try (authorizer ?? Self.authorize)(helper, path)
        } catch {
            if fd >= 0 { close(fd) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func authorize(helper: URL, socketPath: String) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              !helper.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TunWire.error("App 中缺少 TUN 管理程序，请重新构建。")
        }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "exec " + quote(helper.path) + " --tun-session " + quote(socketPath)
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // A non-secret unique argument lets the crash watchdog identify this
        // launcher while an administrator dialog is still pending.
        process.arguments = ["-", socketPath]
        process.standardInput = script
        // No credential is included in the script, arguments or environment.
        try script.fileHandleForWriting.write(contentsOf: Data("do shell script \"\(literal)\" with administrator privileges\n".utf8))
        try script.fileHandleForWriting.close()
        return process
    }

    func connect(configuration: [String: Any]) async throws {
        for _ in 0..<3600 {
            try Task.checkCancellation()
            guard launcher.isRunning else { throw TunWire.error("TUN 管理员授权已取消或启动失败，请查看日志。") }
            let fd = accept(listener, nil, nil)
            if fd >= 0 {
                guard try TunWire.peerUID(fd) == 0 else { close(fd); throw TunWire.error("TUN 管理进程身份无效。") }
                connection = fd
                // Config is small and sent once. Bound writes while preserving UI responsiveness.
                TunWire.configure(fd, nonblocking: true)
                var data = try JSONSerialization.data(withJSONObject: configuration)
                data.append(10)
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    let count = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
                    if count > 0 { offset += count }
                    else if errno == EAGAIN { try await Task.sleep(for: .milliseconds(10)) }
                    else { throw TunWire.error("TUN 配置传输失败。") }
                }
                close(listener); listener = -1
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
                source.setEventHandler { [weak self] in
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    let count = read(fd, &bytes, bytes.count)
                    if count > 0 {
                        let data = Data(bytes.prefix(count))
                        Task { @MainActor [weak self] in self?.receive(data) }
                    } else if count == 0 {
                        Task { @MainActor [weak self] in self?.closeControl() }
                    }
                }
                source.setCancelHandler { close(fd) }
                reader = source
                source.resume()
                return
            }
            if errno != EAGAIN && errno != EINTR { throw TunWire.error("TUN 控制连接失败。") }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TunWire.error("等待 TUN 管理员授权超时。")
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { closeControl(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                if value["event"] as? String == "started" {
                    started = true
                    corePID = value["corePID"] as? Int32
                    supervisorPID = value["supervisorPID"] as? Int32
                }
                if let text = value["text"] as? String { onLog?(text) }
            }
            buffer.removeSubrange(...newline)
        }
    }

    func closeControl() {
        if connection >= 0 {
            // Closing the IPC lease also stops root-owned processes after an app crash.
            shutdown(connection, SHUT_RDWR)
            if let reader { reader.cancel() }
            else { close(connection) }
            connection = -1
        }
        reader = nil
        if listener >= 0 { close(listener); listener = -1 }
        try? FileManager.default.removeItem(at: directory)
    }
}
