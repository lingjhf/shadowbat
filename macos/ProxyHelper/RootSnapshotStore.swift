import Darwin
import Foundation

struct HelperSnapshot: Codable {
    var version = 1
    let ownerUID: UInt32
    let services: [ProxyServiceSnapshot]
}

/// The daemon never reads a client-supplied path or user-writable recovery data.
final class RootSnapshotStore {
    private let directoryFD: Int32
    private let ownerUID: uid_t
    private let fileName = "system-proxy.json"

    init(directory: URL, ownerUID: uid_t = 0) throws {
        self.ownerUID = ownerUID
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw Self.error("无法创建代理备份目录") }
        directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Self.error("无法安全打开代理备份目录") }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == ownerUID,
              info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(directoryFD)
            throw Self.error("代理备份目录的所有者或权限不正确")
        }
    }

    deinit { close(directoryFD) }

    func load() throws -> HelperSnapshot? {
        let fd = openat(directoryFD, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw Self.error("无法读取代理备份") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == ownerUID, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 1_048_576 else {
            throw Self.error("代理备份权限或大小不正确")
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Self.error("读取代理备份失败") }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 1_048_576 else { throw Self.error("代理备份过大") }
        }
        let snapshot = try JSONDecoder().decode(HelperSnapshot.self, from: data)
        guard snapshot.version == 1, snapshot.ownerUID > 0 else { throw Self.error("代理备份版本或用户不正确") }
        return snapshot
    }

    func save(_ snapshot: HelperSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let temporary = "snapshot-\(UUID().uuidString)"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.error("无法创建代理备份") }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.error("写入代理备份失败") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, fileName) == 0,
              fsync(directoryFD) == 0 else { throw Self.error("保存代理备份失败") }
    }

    func remove() throws {
        guard unlinkat(directoryFD, fileName, 0) == 0 || errno == ENOENT else { throw Self.error("删除代理备份失败") }
        guard fsync(directoryFD) == 0 else { throw Self.error("同步代理备份目录失败") }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: ProxyHelperIdentity.serviceName, code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(message)：\(String(cString: strerror(errno)))"])
    }
}
