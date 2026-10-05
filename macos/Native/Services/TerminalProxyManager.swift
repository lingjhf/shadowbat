import Foundation
import Darwin

/// Publishes data for the shell hook; never executes shell startup files in the app.
final class TerminalProxyManager {
    private static let begin = "# >>> Shadowbat terminal proxy >>>"
    private static let end = "# <<< Shadowbat terminal proxy <<<"
    let directory: URL
    let zshrc: URL
    let script: URL
    let stateFile: URL
    private let resource: URL?

    init(directory: URL, zshrc: URL? = nil, resource: URL? = nil) {
        self.directory = directory
        let shellDirectory = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? NSHomeDirectory()
        self.zshrc = (zshrc ?? URL(fileURLWithPath: shellDirectory).appendingPathComponent(".zshrc"))
            .resolvingSymlinksInPath()
        script = directory.appendingPathComponent("terminal-proxy.zsh")
        stateFile = directory.appendingPathComponent("terminal-proxy.state")
        self.resource = resource ?? Bundle.main.url(forResource: "terminal-proxy", withExtension: "zsh")
    }

    var activationCommand: String { "source \(Self.quote(script.path))" }
    var isInstalled: Bool {
        guard let text = try? String(contentsOf: zshrc, encoding: .utf8),
              let range = try? Self.blockRange(in: text) else { return false }
        return text[range] == loader && FileManager.default.fileExists(atPath: script.path)
    }

    func refreshScript() throws {
        guard let resource else { throw ClientError.message("App 中缺少终端集成脚本，请重新构建。") }
        try writePrivate(Data(contentsOf: resource), to: script)
    }

    /// Returns the backup path when an existing startup file was changed.
    @discardableResult
    func install() throws -> URL? {
        let exists = FileManager.default.fileExists(atPath: zshrc.path)
        let previous = exists ? try String(contentsOf: zshrc, encoding: .utf8) : ""
        let range = try Self.blockRange(in: previous)
        var updated = previous
        if let range { updated.replaceSubrange(range, with: loader) }
        else { updated += (previous.isEmpty || previous.hasSuffix("\n") ? "" : "\n") + loader + "\n" }
        try refreshScript()
        guard updated != previous else { return nil }
        var backup: URL?
        let permissions = exists ? try FileManager.default.attributesOfItem(atPath: zshrc.path)[.posixPermissions] : 0o600
        if exists {
            let url = directory.appendingPathComponent("zshrc-backup-\(UUID().uuidString)")
            try writePrivate(Data(previous.utf8), to: url)
            backup = url
        }
        try updated.write(to: zshrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions ?? 0o600], ofItemAtPath: zshrc.path)
        return backup
    }

    func enable(ports: LocalPorts, corePID: Int32) throws {
        try ports.validate()
        guard isInstalled, corePID > 0, kill(corePID, 0) == 0 else {
            throw ClientError.message("请先安装终端集成，并连接一个节点。")
        }
        // No credentials or executable shell text. Both processes must still be alive.
        let state = "1\n\(getpid())\n\(corePID)\n\(ports.http)\n\(ports.socks)\n"
        try writePrivate(Data(state.utf8), to: stateFile)
    }

    func disable() throws {
        if FileManager.default.fileExists(atPath: stateFile.path) {
            try FileManager.default.removeItem(at: stateFile)
        }
    }

    private var loader: String {
        "\(Self.begin)\nif [[ -r \(Self.quote(script.path)) ]]; then\n    source \(Self.quote(script.path))\nfi\n\(Self.end)"
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func blockRange(in text: String) throws -> Range<String.Index>? {
        let begins = text.components(separatedBy: begin).count - 1
        let ends = text.components(separatedBy: end).count - 1
        guard begins != 0 || ends != 0 else { return nil }
        guard begins == 1, ends == 1, let start = text.range(of: begin),
              let finish = text.range(of: end), start.lowerBound < finish.lowerBound else {
            throw ClientError.message(".zshrc 中的 Shadowbat 集成标记不完整或重复，请修复后重试。")
        }
        return start.lowerBound..<finish.upperBound
    }
}
