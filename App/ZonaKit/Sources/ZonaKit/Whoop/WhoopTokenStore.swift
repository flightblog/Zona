import Foundation

/// Persistence seam for WHOOP OAuth tokens. ZonaKit stays storage-agnostic; the
/// app supplies a Keychain-backed impl (tokens are secrets — never UserDefaults).
/// Separate from Strava's `TokenStore` so the two integrations stay decoupled.
/// "Connected to WHOOP?" is derived from `loadTokens() != nil`, so there's no
/// separate flag to keep in sync.
public protocol WhoopTokenStore: Sendable {
    /// The stored tokens, or nil if the user has never connected (or disconnected).
    func loadTokens() -> WhoopTokens?
    /// Persist `tokens`, replacing any existing ones. Because the refresh token
    /// rotates on every refresh, this must not silently fail — a lost save
    /// permanently disconnects the account.
    func save(_ tokens: WhoopTokens)
    /// Forget the tokens ("Disconnect WHOOP").
    func clear()
}

/// A no-op token store (previews/tests that don't persist). Mirrors
/// `EphemeralTokenStore`.
public struct EphemeralWhoopTokenStore: WhoopTokenStore {
    public init() {}
    public func loadTokens() -> WhoopTokens? { nil }
    public func save(_ tokens: WhoopTokens) {}
    public func clear() {}
}
