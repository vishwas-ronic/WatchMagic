import Foundation
import Security

/// Home Assistant token storage in the watch Keychain. The token is never
/// written to UserDefaults or plain files, and never logged.
enum Keychain {
    private static let service = "ai.ronic.watchmagic.homeassistant"
    private static let account = "long-lived-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery
        add.merge(attrs) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
