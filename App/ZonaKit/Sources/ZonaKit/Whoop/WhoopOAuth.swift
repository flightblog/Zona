import Foundation

/// OAuth2 credentials + redirect for the WHOOP app. `clientSecret` is required
/// because WHOOP's token endpoint uses the confidential-client flow (no PKCE), so
/// a native app must hold it to exchange the auth code — acceptable only for a
/// personal, single-user build. The redirect is a custom URL scheme registered in
/// the app's Info.plist, e.g. scheme `zona` + host `whoop-auth` → `zona://whoop-auth`.
public struct WhoopOAuthConfig: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String
    public let redirectScheme: String
    public let redirectHost: String

    public init(clientID: String, clientSecret: String,
                redirectScheme: String, redirectHost: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectScheme = redirectScheme
        self.redirectHost = redirectHost
    }

    /// The full `redirect_uri`, e.g. `zona://whoop-auth`. Must match the redirect
    /// URI configured on the WHOOP developer app and the `callbackURLScheme`
    /// passed to `ASWebAuthenticationSession`.
    public var redirectURI: String { "\(redirectScheme)://\(redirectHost)" }
}

/// Something that went wrong in the authorize/callback leg of the OAuth flow.
public enum WhoopAuthError: Error, Equatable, Sendable {
    /// The user dismissed the web auth sheet (ASWebAuthenticationSession cancel).
    case userCancelled
    /// WHOOP returned `error=access_denied` (user declined the scope).
    case accessDenied
    /// The `state` in the callback didn't match the one we sent (possible CSRF).
    case stateMismatch
    /// Callback carried no `code` parameter.
    case missingCode
    /// The callback URL couldn't be parsed at all.
    case malformedCallback
}

/// Pure request/response modeling for WHOOP OAuth2. No networking: builds the
/// authorize URL, parses the redirect callback, and produces the form bodies for
/// the token endpoint. The app turns these ingredients into live `URLRequest`s,
/// keeping this layer testable without a network (mirrors `StravaOAuth`).
///
/// Differences from Strava: WHOOP requires a `state` param (CSRF guard, ≥8 chars)
/// that we generate and verify on the callback, and the `offline` scope must be
/// present to receive a refresh token.
public enum WhoopOAuth {
    /// Scopes needed to read the two zone inputs (max HR, resting HR). `offline`
    /// is what makes WHOOP return a refresh token.
    public static let scope = "read:body_measurement read:recovery offline"

    public static let authorizeBase = "https://api.prod.whoop.com/oauth/oauth2/auth"
    public static let tokenURL = URL(string: "https://api.prod.whoop.com/oauth/oauth2/token")!

    /// A random `state` value (URL-safe, ≥8 chars) for CSRF protection. Generate
    /// one per authorize attempt, pass it to `authorizeURL`, and hand the same
    /// value to `parseCallback(_:expectedState:)`.
    public static func makeState() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// The authorize URL to hand to `ASWebAuthenticationSession`.
    public static func authorizeURL(config: WhoopOAuthConfig, state: String) -> URL {
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state)
        ]
        return comps.url!
    }

    /// Pull the authorization `code` out of the redirect callback URL, after
    /// checking for an explicit denial and verifying the `state` round-tripped.
    public static func parseCallback(_ url: URL, expectedState: String) -> Result<String, WhoopAuthError> {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformedCallback)
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if value("error") == "access_denied" { return .failure(.accessDenied) }
        // Verify state before trusting the code (CSRF guard).
        guard value("state") == expectedState else { return .failure(.stateMismatch) }
        guard let code = value("code"), !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }

    /// Form body for exchanging an auth `code` for tokens
    /// (`POST /oauth/oauth2/token`, `grant_type=authorization_code`).
    public static func tokenExchangeBody(code: String, config: WhoopOAuthConfig) -> [String: String] {
        [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI
        ]
    }

    /// Form body for refreshing an expired access token
    /// (`POST /oauth/oauth2/token`, `grant_type=refresh_token`). WHOOP requires
    /// the `offline` scope to be re-sent on refresh to keep the refresh token.
    public static func refreshBody(refreshToken: String, config: WhoopOAuthConfig) -> [String: String] {
        [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "scope": "offline"
        ]
    }
}
