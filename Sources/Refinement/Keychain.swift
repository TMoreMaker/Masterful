import Foundation
import MasterfulKit
import Security

/// Keychain storage for the optional cloud provider's API key.
///
/// The key never touches `UserDefaults` or the settings JSON. It is the only
/// secret this app holds, and putting it anywhere else would mean a plain-text
/// credential sitting in a preferences file for the lifetime of the install.
public enum Keychain {
    private static let service = "com.tlotliso.masterful"

    public static func set(_ value: String?, account: String) {
        guard let value, !value.isEmpty else {
            remove(account: account)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // Available without unlocking after first unlock, but never synced
            // to another device — this key is for this Mac.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Log.refinement.error("Keychain add failed (\(addStatus))")
            }
        } else if status != errSecSuccess {
            Log.refinement.error("Keychain update failed (\(status))")
        }
    }

    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func has(account: String) -> Bool {
        get(account: account) != nil
    }

    public static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
