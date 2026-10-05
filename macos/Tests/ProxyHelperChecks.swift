import Darwin
import Foundation

private final class FixturePreferences: ProxyPreferences {
    var values: [String: [String: Any]] = [
        "wifi": ["HTTPEnable": 1, "HTTPProxy": "old.example", "HTTPPort": 8000, "Unrelated": "keep"],
        "ethernet": ["SOCKSEnable": 0]
    ]
    var failCommit = false
    var failRestore = false

    func enable(socks: Int, http: Int, save: ([ProxyServiceSnapshot]) throws -> Void) throws -> [String] {
        let applied = ProxySettings.settings(socks: socks, http: http)
        let items = try values.sorted(by: { $0.key < $1.key }).map { key, settings in
            ProxyServiceSnapshot(serviceID: key, serviceName: key,
                original: try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0),
                applied: try PropertyListSerialization.data(fromPropertyList: applied, format: .binary, options: 0))
        }
        try save(items)
        for key in values.keys { applied.forEach { values[key]![$0.key] = $0.value } }
        if failCommit { throw NSError(domain: "fixture", code: 1) }
        return items.map(\.serviceName)
    }

    func restore(_ services: [ProxyServiceSnapshot]) throws -> [String] {
        if failRestore { throw NSError(domain: "fixture", code: 2) }
        var conflicts: [String] = []
        for service in services {
            guard let current = values[service.serviceID] else { continue }
            let original = try PropertyListSerialization.propertyList(from: service.original, format: nil) as! [String: Any]
            let applied = try PropertyListSerialization.propertyList(from: service.applied, format: nil) as! [String: Any]
            let merged = ProxySettings.restored(current: current, original: original, applied: applied)
            values[service.serviceID] = merged.configuration
            if merged.hadConflicts { conflicts.append(service.serviceName) }
        }
        return conflicts
    }
}

@main
enum ProxyHelperChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "checks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func mustThrow(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw NSError(domain: "checks", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shadowbat-helper-check-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("private")
        let store = try RootSnapshotStore(directory: folder, ownerUID: getuid())
        let fixture = FixturePreferences()
        let original = fixture.values
        let backend = ProxyHelperBackend(store: store, preferences: fixture)
        let session = UUID()
        let uid = getuid()
        let other = UUID()
        for _ in 0..<3 {
            let enabled = try backend.enable(uid: uid, session: session, socks: 1081, http: 1087)
            try check(enabled.active && enabled.hasBackup && enabled.ownerUID == uid, "Missing active lease")
            let saved = try store.load()
            try check(saved?.services.count == 2, "Missing durable recovery snapshot")
            let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("system-proxy.json").path)
            try check(permissions[.posixPermissions] as? Int == 0o600, "Unsafe snapshot permissions")
            try check(fixture.values["wifi"]?["HTTPProxy"] as? String == "127.0.0.1", "Non-loopback proxy written")
            try mustThrow("Another connection replaced the global proxy") {
                _ = try backend.enable(uid: uid, session: other, socks: 2081, http: 2087)
            }
            try mustThrow("Another connection restored an active lease") { _ = try backend.restore(uid: uid, session: other) }
            let restored = try backend.restore(uid: uid, session: session)
            try check(!restored.active && !restored.hasBackup, "Lease persisted after restore")
            try check(NSDictionary(dictionary: fixture.values).isEqual(to: original), "Original settings not restored")
        }
        try mustThrow("Invalid port accepted") { _ = try backend.enable(uid: uid, session: session, socks: 80, http: 1087) }
        try mustThrow("Root client accepted") { _ = try backend.enable(uid: 0, session: session, socks: 1081, http: 1087) }
        print("PASS: durable snapshots, repeated toggles, loopback restriction, port validation, exclusive connection lease")

        _ = try backend.enable(uid: uid, session: session, socks: 1081, http: 1087)
        fixture.values["wifi"]?["SOCKSProxy"] = "changed-by-other-app"
        fixture.values["wifi"]?["Unrelated"] = "new-value"
        let conflict = try backend.restore(uid: uid, session: session)
        try check(conflict.conflicts == ["wifi"], "Concurrent edits not reported")
        try check(fixture.values["wifi"]?["SOCKSProxy"] as? String == "changed-by-other-app", "Concurrent proxy edit overwritten")
        try check(fixture.values["wifi"]?["Unrelated"] as? String == "new-value", "Unrelated edit overwritten")
        fixture.values = original

        _ = try backend.enable(uid: uid, session: session, socks: 1081, http: 1087)
        try backend.disconnected(session: other)
        let stillActive = try backend.status()
        try check(stillActive.active, "Unrelated disconnect revoked the lease")
        try backend.disconnected(session: session)
        let noBackup = try backend.status()
        try check(!noBackup.hasBackup, "App crash left proxy settings enabled")

        fixture.failCommit = true
        try mustThrow("Failed commit accepted") { _ = try backend.enable(uid: uid, session: session, socks: 1081, http: 1087) }
        let commitBackup = try backend.status()
        try check(commitBackup.hasBackup, "Failed commit lost recovery snapshot")
        fixture.failCommit = false
        try backend.disconnected(session: session)
        try check(NSDictionary(dictionary: fixture.values).isEqual(to: original), "Failed commit not rolled back")

        _ = try backend.enable(uid: uid, session: session, socks: 1081, http: 1087)
        fixture.failRestore = true
        try mustThrow("Restore failure was ignored") { try backend.disconnected(session: session) }
        let pending = try backend.status()
        try check(pending.hasBackup && !pending.active, "Failed restore is not recoverable")
        fixture.failRestore = false
        try mustThrow("Another user consumed the snapshot") { _ = try backend.restore(uid: uid + 1, session: other) }
        _ = try backend.restore(uid: uid, session: other)

        _ = try backend.enable(uid: uid, session: session, socks: 1081, http: 1087)
        let restarted = ProxyHelperBackend(store: store, preferences: fixture)
        _ = try restarted.restoreOrphan()
        try check(NSDictionary(dictionary: fixture.values).isEqual(to: original), "Daemon startup recovery failed")
        print("PASS: conflict-safe restore, app crash, failed commit, failed restore, user isolation, daemon restart")

        let link = base.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        try mustThrow("Symlink backup directory accepted") { _ = try RootSnapshotStore(directory: link, ownerUID: uid) }
        let publicFolder = base.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: publicFolder.path)
        try mustThrow("Public backup directory accepted") { _ = try RootSnapshotStore(directory: publicFolder, ownerUID: uid) }
        let outside = base.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        let backup = folder.appendingPathComponent("system-proxy.json")
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: outside)
        try mustThrow("Symlink recovery data accepted") { _ = try store.load() }
        try FileManager.default.removeItem(at: backup)
        let preserved = try Data(contentsOf: outside)
        try check(preserved == Data("keep".utf8), "Symlink target was modified")
        try Data(repeating: 0, count: 1_048_577).write(to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        try mustThrow("Oversized recovery data accepted") { _ = try store.load() }
        print("PASS: private storage, symlink rejection, bounded recovery data")
    }
}
