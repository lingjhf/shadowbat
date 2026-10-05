import Foundation
import Security

enum ProxyHelperIdentity {
    static let serviceName = "com.lingj.shadowbat.proxy-helper"
    static let plistName = serviceName + ".plist"
    static let appIdentifier = "com.lingj.shadowbat"

    static func requirement(identifier: String) throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw NSError(domain: serviceName, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法验证开发团队签名，请使用已签名的 Shadowbat。"])
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

@objc protocol ProxyHelperProtocol {
    func status(withReply reply: @escaping (Data?, String?) -> Void)
    func enable(socksPort: Int, httpPort: Int, withReply reply: @escaping (Data?, String?) -> Void)
    func restore(withReply reply: @escaping (Data?, String?) -> Void)
}

struct ProxyHelperStatus: Codable {
    var version = 1
    var hasBackup: Bool
    var active: Bool
    var ownerUID: UInt32?
    var serviceNames: [String] = []
    var conflicts: [String] = []
}
