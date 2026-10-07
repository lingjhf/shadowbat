import Darwin
import Foundation
import SystemConfiguration
import os

private let logger = Logger(subsystem: ProxyHelperIdentity.serviceName, category: "daemon")

// This administrator-authorized, per-session path never registers or weakens the XPC service.
if CommandLine.arguments.dropFirst().first == "--tun-session" {
    do {
        guard CommandLine.arguments.count == 3 else { throw TunWire.error("TUN 参数无效。") }
        let core = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("sing-box")
        try TunSessionSupervisor.run(socketPath: CommandLine.arguments[2], coreURL: core)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

private final class HelperSession: NSObject, ProxyHelperProtocol {
    let id = UUID()
    let uid: uid_t
    private let backend: ProxyHelperBackend
    private let queue: DispatchQueue

    init(uid: uid_t, backend: ProxyHelperBackend, queue: DispatchQueue) {
        self.uid = uid; self.backend = backend; self.queue = queue
    }

    func status(withReply reply: @escaping (Data?, String?) -> Void) {
        perform(reply) { try self.backend.status() }
    }

    func enable(socksPort: Int, httpPort: Int, withReply reply: @escaping (Data?, String?) -> Void) {
        perform(reply) {
            var consoleUID: uid_t = 0
            _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
            guard consoleUID == self.uid else {
                throw NSError(domain: ProxyHelperIdentity.serviceName, code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "只有当前登录桌面的用户可以开启系统代理。"])
            }
            return try self.backend.enable(uid: self.uid, session: self.id, socks: socksPort, http: httpPort)
        }
    }

    func restore(withReply reply: @escaping (Data?, String?) -> Void) {
        perform(reply) { try self.backend.restore(uid: self.uid, session: self.id) }
    }

    private func perform(_ reply: @escaping (Data?, String?) -> Void, _ work: @escaping () throws -> ProxyHelperStatus) {
        queue.async {
            do { reply(try JSONEncoder().encode(work()), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }
}

private final class HelperListener: NSObject, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: ProxyHelperIdentity.serviceName)
    private let backend: ProxyHelperBackend
    private let requirement: String

    init(backend: ProxyHelperBackend, requirement: String) {
        self.backend = backend; self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        // XPC checks the peer signature on messages, avoiding PID-based identity races.
        connection.setCodeSigningRequirement(requirement)
        let session = HelperSession(uid: connection.effectiveUserIdentifier, backend: backend, queue: queue)
        connection.exportedInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        connection.exportedObject = session
        let id = session.id
        connection.invalidationHandler = { [backend, queue] in
            queue.async {
                do { try backend.disconnected(session: id) }
                catch { logger.error("Automatic proxy restoration failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        connection.resume()
        return true
    }
}

do {
    guard geteuid() == 0 else { throw NSError(domain: ProxyHelperIdentity.serviceName, code: 6,
                                             userInfo: [NSLocalizedDescriptionKey: "此程序应由已授权的系统后台服务启动。"] ) }
    let requirement = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier)
    let directory = URL(fileURLWithPath: "/Library/Application Support/com.lingj.shadowbat.helper", isDirectory: true)
    let store = try RootSnapshotStore(directory: directory)
    let backend = ProxyHelperBackend(store: store, preferences: SystemProxyPreferences())
    do { _ = try backend.restoreOrphan() }
    catch { logger.error("Startup proxy recovery failed: \(error.localizedDescription, privacy: .public)") }
    let delegate = HelperListener(backend: backend, requirement: requirement)
    let listener = NSXPCListener(machServiceName: ProxyHelperIdentity.serviceName)
    listener.delegate = delegate
    listener.resume()
    withExtendedLifetime(delegate) { RunLoop.current.run() }
} catch {
    logger.error("Proxy helper could not start: \(error.localizedDescription, privacy: .public)")
    exit(1)
}
