import Darwin
import Foundation

final class InstanceLock {
    private let descriptor: Int32

    init(directory: URL) throws {
        descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClientError.message("无法创建运行锁。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ClientError.message("Shadowbat 已在运行，请使用已有窗口或菜单栏图标。")
        }
    }

    deinit { close(descriptor) }
}
