import Foundation
import Security

struct KeychainStore {
    var service = "com.lingj.shadowbat.passwords"

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    func read(_ id: UUID) throws -> String? {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ClientError.message("钥匙串中的密码无法读取。")
        }
        return value
    }

    func save(_ password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(id)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(attributes as CFDictionary, nil))
        } else { try check(status) }
    }

    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "错误 \(status)"
            throw ClientError.message("钥匙串操作失败：\(text)")
        }
    }
}
