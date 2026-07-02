import Foundation

/// OAuth2 credentials + redirect for the Strava app. `clientSecret` is required
/// because Strava's token endpoint has no PKCE, so a native app must hold it to
/// exchange the auth code — acceptable only for a personal, single-user build.
/// The redirect is a custom URL scheme registered in the app's Info.plist, e.g.
/// scheme `zona` + host `strava-auth` → `zona://strava-auth`.
public struct StravaOAuthConfig: Sendable, Equatable {
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

    /// The full `redirect_uri`, e.g. `zona://strava-auth`. Must match the
    /// "Authorization Callback Domain" configured on the Strava API app and the
    /// `callbackURLScheme` passed to `ASWebAuthenticationSession`.
    public var redirectURI: String { "\(redirectScheme)://\(redirectHost)" }
}

/// Something that went wrong in the authorize/callback leg of the OAuth flow.
public enum StravaAuthError: Error, Equatable, Sendable {
    /// The user dismissed the web auth sheet (ASWebAuthenticationSession cancel).
    case userCancelled
    /// Strava returned `error=access_denied` (user declined the scope).
    case accessDenied
    /// Callback carried no `code` parameter.
    case missingCode
    /// The granted scope didn't include `activity:write`, so uploads would fail.
    case missingScope
    /// The callback URL couldn't be parsed at all.
    case malformedCallback
}

/// Pure request/response modeling for Strava OAuth2. No networking: builds the
/// authorize URL, parses the redirect callback, and produces the form bodies for
/// the token endpoint. The app turns these ingredients into live `URLRequest`s,
/// keeping this layer testable without a network (mirrors `TCXExporter` returning
/// a `String`).
public enum StravaOAuth {
    /// Scope needed to create uploads/activities.
    public static let scope = "activity:write"

    public static let authorizeBase = "https://www.strava.com/oauth/mobile/authorize"
    public static let tokenURL = URL(string: "https://www.strava.com/oauth/token")!

    /// The authorize URL to hand to `ASWebAuthenticationSession`.
    public static func authorizeURL(config: StravaOAuthConfig) -> URL {
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: scope)
        ]
        return comps.url!
    }

    /// Pull the authorization `code` out of the redirect callback URL, after
    /// checking for an explicit denial and that the granted scope covers uploads.
    public static func parseCallback(_ url: URL) -> Result<String, StravaAuthError> {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformedCallback)
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if value("error") == "access_denied" { return .failure(.accessDenied) }
        guard let code = value("code"), !code.isEmpty else { return .failure(.missingCode) }
        // Strava returns the granted scopes as a comma-separated `scope` param.
        let granted = (value("scope") ?? "").split(separator: ",").map(String.init)
        guard granted.contains(scope) else { return .failure(.missingScope) }
        return .success(code)
    }

    /// Form body for exchanging an auth `code` for tokens
    /// (`POST /oauth/token`, `grant_type=authorization_code`).
    public static func tokenExchangeBody(code: String, config: StravaOAuthConfig) -> [String: String] {
        [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "code": code,
            "grant_type": "authorization_code"
        ]
    }

    /// Form body for refreshing an expired access token
    /// (`POST /oauth/token`, `grant_type=refresh_token`).
    public static func refreshBody(refreshToken: String, config: StravaOAuthConfig) -> [String: String] {
        [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
    }
}
