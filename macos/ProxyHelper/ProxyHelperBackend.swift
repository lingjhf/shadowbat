import Foundation

/// All calls are serialized by the daemon. A live connection owns the global proxy lease.
final class ProxyHelperBackend {
    private let store: RootSnapshotStore
    private let preferences: ProxyPreferences
    private var lease: UUID?
    private var ownerUID: UInt32?

    init(store: RootSnapshotStore, preferences: ProxyPreferences) {
        self.store = store
        self.preferences = preferences
    }

    func status() throws -> ProxyHelperStatus {
        let saved = try store.load()
        return ProxyHelperStatus(hasBackup: saved != nil, active: lease != nil,
                                 ownerUID: saved?.ownerUID, serviceNames: saved?.services.map(\.serviceName) ?? [])
    }

    func enable(uid: UInt32, session: UUID, socks: Int, http: Int) throws -> ProxyHelperStatus {
        try ProxySettings.validate(socks: socks, http: http)
        guard uid > 0 else { throw failure("系统代理只能由已登录用户启用。") }
        guard lease == nil, try store.load() == nil else { throw failure("系统代理已被使用或有待恢复的备份，请先恢复。") }
        // Assign the lease first: even a failed commit is recovered on connection loss.
        lease = session
        ownerUID = uid
        do {
            _ = try preferences.enable(socks: socks, http: http) { services in
                try store.save(HelperSnapshot(ownerUID: uid, services: services))
            }
            return try status()
        } catch {
            // A read failure is not evidence that no recovery data exists.
            do {
                if try store.load() == nil { lease = nil; ownerUID = nil }
            } catch { /* Preserve the lease so disconnection still attempts recovery. */ }
            throw error
        }
    }

    func restore(uid: UInt32, session: UUID) throws -> ProxyHelperStatus {
        guard lease == nil || lease == session else { throw failure("另一个 Shadowbat 连接正在使用系统代理。") }
        if let snapshot = try store.load(), snapshot.ownerUID != uid { throw failure("系统代理备份属于另一位用户。") }
        return try restoreOrphan()
    }

    /// Invoked at daemon startup or after the owning connection dies.
    func restoreOrphan() throws -> ProxyHelperStatus {
        var conflicts: [String] = []
        if let snapshot = try store.load() {
            conflicts = try preferences.restore(snapshot.services)
            try store.remove()
        }
        lease = nil
        ownerUID = nil
        var result = try status()
        result.conflicts = conflicts
        return result
    }

    func disconnected(session: UUID) throws {
        guard lease == session else { return }
        // An unsuccessful restore must remain recoverable by a later connection.
        defer { lease = nil; ownerUID = nil }
        _ = try restoreOrphan()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: ProxyHelperIdentity.serviceName, code: 4, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
