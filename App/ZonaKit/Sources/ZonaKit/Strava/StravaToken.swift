import Foundation

/// The JSON Strava returns from `POST /oauth/token` (both the code exchange and a
/// refresh). Only the fields we use are decoded.
public struct StravaTokenResponse: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Access-token expiry as a Unix timestamp (seconds).
    public let expiresAt: Int
    public let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case tokenType = "token_type"
    }
}

/// The credentials we persist between launches. The access token is a 6-hour
/// cache; the refresh token is the durable secret and **rotates on every
/// refresh** — persisting the new one is mandatory or the next refresh fails.
public struct StravaTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Build from a fresh token response, mapping the Unix expiry to a `Date`.
    public init(from response: StravaTokenResponse) {
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken
        self.expiresAt = Date(timeIntervalSince1970: TimeInterval(response.expiresAt))
    }

    /// True when the access token is at or past expiry, minus `leeway` so we
    /// refresh a little early rather than mid-request. Default leeway 300 s.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}
