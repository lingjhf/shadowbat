import Darwin
import Foundation

/// Signed-app CLI for service setup and validation; it never loads profiles or Keychain data.
@MainActor
enum ProxyHelperCommand {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let command = arguments.dropFirst().first,
              ["--install-proxy-helper", "--uninstall-proxy-helper", "--proxy-helper-status", "--verify-proxy-helper"].contains(command) else { return }
        setbuf(stdout, nil)
        let helper = ProxyHelperClient()
        Task { @MainActor in
            do {
                switch command {
                case "--install-proxy-helper":
                    try helper.register()
                    print("系统代理辅助程序：\(helper.installation.label)")
                    if helper.installation == .needsApproval {
                        print("请在系统设置 → 通用 → 登录项与扩展中，允许 Shadowbat 后台辅助程序。")
                        helper.openApprovalSettings()
                    }
                case "--uninstall-proxy-helper":
                    try await helper.unregister()
                    print("系统代理辅助程序已卸载。")
                case "--proxy-helper-status":
                    print("系统代理辅助程序：\(helper.installation.label)")
                    if helper.installation == .ready {
                        let status = try await helper.status()
                        print(String(decoding: try JSONEncoder().encode(status), as: UTF8.self))
                    }
                default:
                    // Explicitly requested verification only. Preserve an existing helper lease.
                    let initial = try await helper.status()
                    guard !initial.hasBackup else { throw ClientError.message("辅助程序已有活动备份，跳过验证以保留当前连接。") }
                    guard arguments.count == 4, let socks = Int(arguments[2]), let http = Int(arguments[3]) else {
                        throw ClientError.message("用法：--verify-proxy-helper SOCKS端口 HTTP端口")
                    }
                    let ports = LocalPorts(socks: socks, http: http)
                    do {
                        for _ in 0..<3 {
                            let enabled = try await helper.enable(ports: ports)
                            guard enabled.active && enabled.hasBackup else { throw ClientError.message("辅助程序未保存恢复备份。") }
                            let restored = try await helper.restore()
                            guard !restored.active && !restored.hasBackup else { throw ClientError.message("辅助程序未恢复代理。") }
                        }
                    } catch {
                        _ = try? await helper.restore()
                        throw error
                    }
                    print("PASS: three proxy enable/restore cycles through the authorized helper")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }
}
