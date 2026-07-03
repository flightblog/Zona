import Foundation

/// The JSON WHOOP returns from `POST /oauth/oauth2/token` (both the code exchange
/// and a refresh). Only the fields we use are decoded. Unlike Strava, WHOOP gives
/// `expires_in` (seconds from *now*), not an absolute `expires_at` timestamp.
public struct WhoopTokenResponse: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Access-token lifetime in seconds from the moment of issue.
    public let expiresIn: Int
    public let tokenType: String
    /// Space-separated granted scopes (WHOOP echoes these back).
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

/// The credentials we persist between launches. The access token is short-lived
/// (~1 hour); the refresh token is the durable secret and **rotates on every
/// refresh** — persisting the new one is mandatory or the next refresh fails.
public struct WhoopTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Build from a fresh token response, turning the relative `expires_in` into an
    /// absolute expiry off `now` (injectable for tests).
    public init(from response: WhoopTokenResponse, now: Date = Date()) {
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken
        self.expiresAt = now.addingTimeInterval(TimeInterval(response.expiresIn))
    }

    /// True when the access token is at or past expiry, minus `leeway` so we
    /// refresh a little early rather than mid-request. Default leeway 120 s (the
    /// token only lives ~1 h, so a smaller cushion than Strava's).
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 120) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}
