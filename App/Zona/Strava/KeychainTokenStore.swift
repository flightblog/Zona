import Foundation
import Security
import ZonaKit

/// Keychain-backed `TokenStore`. Stores the whole `StravaTokens` (which includes
/// the rotating refresh token) as one JSON generic-password item. Parallels
/// `SensorMemoryStore`, but uses the Keychain because these are secrets.
///
/// Accessibility is `...AfterFirstUnlockThisDeviceOnly`: available after the
/// first unlock (so a token survives a reboot), never leaves the device, and
/// crucially does **not** iCloud-sync — the refresh token rotates on every
/// refresh, so syncing it would let two devices invalidate each other's token.
struct KeychainTokenStore: TokenStore {
    private let service = "org.flightblog.zona.strava"
    private let account = "oauth-tokens"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func loadTokens() -> StravaTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StravaTokens.self, from: data)
    }

    func save(_ tokens: StravaTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else {
            assertionFailure("Strava tokens failed to encode")
            return
        }
        // Upsert: try to update an existing item; if none, add one. A silent
        // failure here permanently disconnects the account (the old refresh token
        // is already invalidated), so surface it in debug builds.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            assert(addStatus == errSecSuccess, "Keychain add failed: \(addStatus)")
        } else {
            assert(updateStatus == errSecSuccess, "Keychain update failed: \(updateStatus)")
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
