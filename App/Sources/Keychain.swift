import Foundation
import Security

/// Minimal Keychain-backed string store for the one secret the app holds —
/// the paid-triage account bearer token. Credentials belong in the Keychain,
/// not in a `UserDefaults` plist that any process with the user's file access
/// can read. Scoped `WhenUnlockedThisDeviceOnly` (no iCloud sync, no access
/// while locked).
enum Keychain {
    private static let service = "bot.anomalous.sensor"

    /// Pin the item to an EXPLICIT, stable access group instead of relying on
    /// the process's default group. Without this, the token lands in whatever
    /// the first `keychain-access-groups` entry happens to be at sign time — so
    /// a change in the entitlement (or dev re-sign churn) writes it to one group
    /// and reads it from another, and the token silently "disappears" after an
    /// update. The team-prefixed literal is required: `$(AppIdentifierPrefix)`
    /// is NOT expanded when codesign applies entitlements. Must match a group in
    /// the app's keychain-access-groups entitlement.
    private static let accessGroup = "7JQGQ7CRH8.bot.anomalous.sensor.shared"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        // Empty string clears the credential.
        guard !value.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }
}
