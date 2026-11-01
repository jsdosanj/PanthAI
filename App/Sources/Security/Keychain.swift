import Foundation
import LocalAuthentication
import Security

/// Minimal Keychain wrapper. Ordinary secrets (API tokens) sync through the user's iCloud Keychain, which is
/// end-to-end encrypted. SSH keys and passwords stay on this iPad and can require Face ID / passcode on every use.
enum Keychain {
    private static let service = "com.dosanjhlabs.dosanjhai"

    /// One shared authentication, so connecting to several machines in a row asks for Face ID once.
    nonisolated(unsafe) private static let authContext: LAContext = {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 30
        return context
    }()

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = authContext
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func exists(_ account: String) -> Bool {
        var q = query(account)
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// - Parameter requireUserPresence: store on this device only, readable only after Face ID / Touch ID / passcode.
    @discardableResult
    static func set(_ value: String, for account: String, synchronizable: Bool = true, requireUserPresence: Bool = false) -> Bool {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        if requireUserPresence {
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) else { return false }
            q[kSecAttrAccessControl as String] = access
            q[kSecAttrSynchronizable as String] = false
        } else {
            q[kSecAttrSynchronizable as String] = synchronizable
            q[kSecAttrAccessible as String] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// Removes every item this app stored.
    static func deleteAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        SecItemDelete(q as CFDictionary)
    }
}
