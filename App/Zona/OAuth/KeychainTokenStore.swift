import Foundation
import Security
import ZonaKit

/// Keychain-backed `TokenStore` for any provider. Stores the whole token struct
/// (which includes the rotating refresh token) as one JSON generic-password item,
/// keyed by a per-provider `service` string passed at init. Parallels
/// `SensorMemoryStore`, but uses the Keychain because these are secrets.
///
/// Accessibility is `...AfterFirstUnlockThisDeviceOnly`: available after the
/// first unlock (so a token survives a reboot), never leaves the device, and
/// crucially does **not** iCloud-sync — the refresh token rotates on every
/// refresh, so syncing it would let two devices invalidate each other's token.
///
/// The `service` strings are load-bearing: existing users' tokens live under
/// `org.flightblog.zona.strava` / `org.flightblog.zona.whoop`, so those exact
/// values must be preserved (see the `.strava` / `.whoop` factories below).
struct KeychainTokenStore<Tokens: Codable & Sendable>: TokenStore {
    private let service: String
    private let account = "oauth-tokens"

    init(service: String) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func loadTokens() -> Tokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    func save(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else {
            assertionFailure("OAuth tokens failed to encode for \(service)")
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

extension KeychainTokenStore where Tokens == StravaTokens {
    /// The Strava token store. The `service` string must not change — existing
    /// users' tokens are stored under it.
    static func strava() -> KeychainTokenStore<StravaTokens> {
        KeychainTokenStore(service: "org.flightblog.zona.strava")
    }
}

extension KeychainTokenStore where Tokens == WhoopTokens {
    /// The WHOOP token store. The `service` string must not change — existing
    /// users' tokens are stored under it.
    static func whoop() -> KeychainTokenStore<WhoopTokens> {
        KeychainTokenStore(service: "org.flightblog.zona.whoop")
    }
}
