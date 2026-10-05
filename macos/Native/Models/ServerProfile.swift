import Foundation

struct ServerProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int
    var method: String
    var participatesInAutomaticSelection = true

    static let methods = [
        "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305"
    ]

    func validate(password: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.message("请填写节点名称。")
        }
        guard !host.isEmpty, host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.contains(where: { $0.isWhitespace }), !host.contains("://"),
              !host.contains("/"), !host.contains("@") else {
            throw ClientError.message("请填写域名或 IP 地址，不要包含协议或路径。")
        }
        guard (1...65535).contains(port) else { throw ClientError.message("服务器端口应为 1–65535。") }
        guard Self.methods.contains(method) else { throw ClientError.message("不支持此加密方式。") }
        guard !password.isEmpty else { throw ClientError.message("请填写密码或密钥。") }
        if method.hasPrefix("2022-") {
            let count = method == "2022-blake3-aes-128-gcm" ? 16 : 32
            guard password.split(separator: ":", omittingEmptySubsequences: false).allSatisfy({
                Data(base64Encoded: String($0))?.count == count
            }) else { throw ClientError.message("此加密方式需要 Base64 编码的 \(count) 字节密钥。") }
        }
    }
}

extension ServerProfile {
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, method, participatesInAutomaticSelection
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        method = try values.decode(String.self, forKey: .method)
        participatesInAutomaticSelection = try values.decodeIfPresent(Bool.self, forKey: .participatesInAutomaticSelection) ?? true
    }
}

enum NodeSelectionMode: String, CaseIterable, Identifiable {
    case automatic, manual
    var id: String { rawValue }
    var label: String { self == .automatic ? "自动选择" : "手动选择" }

    func candidates(in profiles: [ServerProfile], manualID: UUID?) -> [ServerProfile] {
        switch self {
        case .automatic: return profiles.filter(\.participatesInAutomaticSelection)
        case .manual: return profiles.filter { $0.id == manualID }
        }
    }
}

/// Credentials exist only in memory and in the private, temporary core configuration.
struct ProxyServer {
    let profile: ServerProfile
    let password: String
}

struct LocalPorts: Equatable {
    var socks = 1081
    var http = 1087

    func validate() throws {
        guard (1024...65535).contains(socks), (1024...65535).contains(http), socks != http else {
            throw ClientError.message("本地端口应为 1024–65535，且 SOCKS5 与 HTTP 端口不能相同。")
        }
    }
}

enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}
