import Foundation

/// Persistence seam for OAuth tokens (Strava, WHOOP, any future provider). ZonaKit
/// stays storage-agnostic; the app supplies a Keychain-backed impl (tokens are
/// secrets — never UserDefaults). Mirrors `SensorMemory`. "Connected?" is derived
/// from `loadTokens() != nil`, so there's no separate flag to keep in sync.
///
/// Generic over the token type so one protocol serves every provider — the stored
/// shape (`StravaTokens`, `WhoopTokens`) is the only thing that differs.
public protocol TokenStore<Tokens>: Sendable {
    associatedtype Tokens: Codable & Sendable

    /// The stored tokens, or nil if the user has never connected (or disconnected).
    func loadTokens() -> Tokens?
    /// Persist `tokens`, replacing any existing ones. Because the refresh token
    /// rotates on every refresh, this must not silently fail — a lost save
    /// permanently disconnects the account.
    func save(_ tokens: Tokens)
    /// Forget the tokens ("Disconnect").
    func clear()
}

/// A no-op token store (previews/tests that don't persist). Mirrors
/// `EphemeralSensorMemory`.
public struct EphemeralTokenStore<Tokens: Codable & Sendable>: TokenStore {
    public init() {}
    public func loadTokens() -> Tokens? { nil }
    public func save(_ tokens: Tokens) {}
    public func clear() {}
}
