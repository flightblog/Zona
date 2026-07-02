import Foundation

/// Persistence seam for Strava OAuth tokens. ZonaKit stays storage-agnostic; the
/// app supplies a Keychain-backed impl (tokens are secrets — never UserDefaults).
/// Mirrors `SensorMemory`. "Connected to Strava?" is derived from
/// `loadTokens() != nil`, so there's no separate flag to keep in sync.
public protocol TokenStore: Sendable {
    /// The stored tokens, or nil if the user has never connected (or disconnected).
    func loadTokens() -> StravaTokens?
    /// Persist `tokens`, replacing any existing ones. Because the refresh token
    /// rotates on every refresh, this must not silently fail — a lost save
    /// permanently disconnects the account.
    func save(_ tokens: StravaTokens)
    /// Forget the tokens ("Disconnect Strava").
    func clear()
}

/// A no-op token store (previews/tests that don't persist). Mirrors
/// `EphemeralSensorMemory`.
public struct EphemeralTokenStore: TokenStore {
    public init() {}
    public func loadTokens() -> StravaTokens? { nil }
    public func save(_ tokens: StravaTokens) {}
    public func clear() {}
}
