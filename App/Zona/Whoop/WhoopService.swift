import Foundation
import ZonaKit

/// Networking errors surfaced to the UI.
enum WhoopServiceError: Error {
    case notAuthorized                       // no tokens stored; must authorize first
    case refreshTokenExpired                 // stored refresh token is dead; reconnect needed
    case http(status: Int, body: String)     // non-2xx from WHOOP
    case decoding                            // response didn't decode
    case noRestingHR                         // recovery came back with no scored resting HR
}

/// The networking layer for WHOOP: token exchange, refresh, and the two GETs that
/// supply the HRR-zone inputs (max HR + resting HR). All URL/body/decoding logic
/// is delegated to the pure ZonaKit helpers (`WhoopOAuth`, `WhoopTokens`,
/// `WhoopBodyMeasurement`, `WhoopRecoveryPage`); this actor only does the I/O.
///
/// An `actor` for the usual reasons, but note that actor isolation alone does
/// **not** serialize a token refresh — it's released at every `await`, so two
/// concurrent fetches could each refresh with the same single-use token. That's
/// what `ZonaKit`'s `TokenRefresher` is for; see its doc comment.
actor WhoopService {
    private let config: WhoopOAuthConfig
    private let tokens: any TokenStore<WhoopTokens>
    private let session: URLSession

    private static let apiBase = URL(string: "https://api.prod.whoop.com/developer")!

    /// Serializes refreshes so concurrent GETs share one round-trip. Built lazily
    /// because it closes over `self` to perform the POST.
    private var refresher: TokenRefresher<WhoopTokens>?

    init(config: WhoopOAuthConfig, tokens: any TokenStore<WhoopTokens>, session: URLSession = .shared) {
        self.config = config
        self.tokens = tokens
        self.session = session
    }

    var isConnected: Bool { tokens.loadTokens() != nil }

    func disconnect() { tokens.clear() }

    /// Drop tokens WHOOP has refused to refresh. Separate from `disconnect()` so
    /// the intent reads clearly at the call site: this isn't the user leaving, it's
    /// a credential that can no longer work being discarded so the next attempt
    /// starts a fresh authorization instead of replaying a dead token.
    private func clearDeadTokens() { tokens.clear() }

    // MARK: OAuth

    /// Exchange an authorization `code` (from ASWebAuthenticationSession) for
    /// tokens and persist them.
    @discardableResult
    func exchange(code: String) async throws -> WhoopTokens {
        let body = WhoopOAuth.tokenExchangeBody(code: code, config: config)
        let response = try await postForm(WhoopOAuth.tokenURL, fields: body, accessToken: nil)
        let decoded = try Self.decode(WhoopTokenResponse.self, from: response)
        let newTokens = WhoopTokens(from: decoded)
        tokens.save(newTokens)
        return newTokens
    }

    /// A currently-valid access token, refreshing first if the cached one is at
    /// or near expiry. Persists the rotated refresh token.
    ///
    /// Delegates to `TokenRefresher` so that the two concurrent GETs behind
    /// `fetchZonesAndRecovery` share a single refresh: WHOOP's refresh token is
    /// single-use, so a second simultaneous refresh presents an
    /// already-invalidated token and comes back HTTP 400.
    func validAccessToken() async throws -> String {
        do {
            return try await tokenRefresher().validAccessToken()
        } catch TokenRefreshError.notAuthorized {
            throw WhoopServiceError.notAuthorized
        }
    }

    /// The lazily-built shared refresher. One instance per service, so the
    /// in-flight refresh is actually shared between callers.
    private func tokenRefresher() -> TokenRefresher<WhoopTokens> {
        if let refresher { return refresher }
        let built = TokenRefresher<WhoopTokens>(
            store: tokens,
            isExpired: { $0.isExpired() },
            accessToken: { $0.accessToken },
            refresh: { [config] current in
                let body = WhoopOAuth.refreshBody(refreshToken: current.refreshToken, config: config)
                do {
                    let response = try await self.postForm(WhoopOAuth.tokenURL, fields: body, accessToken: nil)
                    return WhoopTokens(from: try Self.decode(WhoopTokenResponse.self, from: response))
                } catch let WhoopServiceError.http(status, errorBody) {
                    // A refresh token WHOOP won't honour can never start working
                    // again, so clear it rather than leaving the account wedged in
                    // a state where every retry re-fails on the same dead token.
                    if WhoopTokenErrorKind.classify(body: errorBody, grantType: "refresh_token")
                        == .deadRefreshToken {
                        await self.clearDeadTokens()
                        throw WhoopServiceError.refreshTokenExpired
                    }
                    throw WhoopServiceError.http(status: status, body: errorBody)
                }
            })
        refresher = built
        return built
    }

    // MARK: Zone inputs

    /// Max HR and body weight plus the latest recovery in one shot — the body
    /// measurement and the recovery page are fetched concurrently, and the
    /// recovery page is decoded once for both resting HR (zones) and the
    /// readiness display. `recovery` is nil when WHOOP has no scored recovery
    /// yet; `weightKg` is nil when WHOOP has no weight on file for the account
    /// (it's optional on WHOOP's side too). This is the single "refresh" call
    /// the UI makes.
    func fetchZonesAndRecovery() async throws -> (maxHR: Int, weightKg: Double?, recovery: WhoopRecovery?) {
        async let measurement = fetchBodyMeasurement()
        async let recovery = fetchRecovery()
        let (body, recoveryResult) = try await (measurement, recovery)
        return (body.maxHeartRate, body.weightKilogram, recoveryResult)
    }

    /// `GET /v2/user/measurement/body` → max heart rate.
    func fetchMaxHR() async throws -> Int {
        try await fetchBodyMeasurement().maxHeartRate
    }

    /// `GET /v2/user/measurement/body`, decoded once and shared by `fetchMaxHR`
    /// and `fetchZonesAndRecovery`.
    private func fetchBodyMeasurement() async throws -> WhoopBodyMeasurement {
        let url = Self.apiBase.appendingPathComponent("v2/user/measurement/body")
        let data = try await authorizedGet(url)
        return try Self.decode(WhoopBodyMeasurement.self, from: data)
    }

    /// `GET /v2/recovery` (newest first) → resting HR from the latest scored
    /// record.
    func fetchRestingHR() async throws -> Int {
        guard let rhr = try await fetchRecoveryPage().latestRestingHR else {
            throw WhoopServiceError.noRestingHR
        }
        return rhr
    }

    // MARK: Readiness

    /// The latest scored WHOOP recovery (recovery %, HRV, resting HR) for the
    /// setup-screen readiness display, or nil if WHOOP hasn't scored a recent one.
    func fetchRecovery() async throws -> WhoopRecovery? {
        try await fetchRecoveryPage().latestRecovery
    }

    /// `GET /v2/recovery` (newest first). `limit=10` gives headroom to skip a
    /// still-calibrating top record. Shared by resting-HR and readiness fetches.
    private func fetchRecoveryPage() async throws -> WhoopRecoveryPage {
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent("v2/recovery"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: "10")]
        let data = try await authorizedGet(comps.url!)
        return try Self.decode(WhoopRecoveryPage.self, from: data)
    }

    // MARK: HTTP plumbing

    /// GET with a freshly-validated bearer token.
    private func authorizedGet(_ url: URL) async throws -> Data {
        let token = try await validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    /// POST an `application/x-www-form-urlencoded` body (the token endpoint).
    private func postForm(_ url: URL, fields: [String: String], accessToken: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = FormURLEncoding.bodyData(fields)
        return try await send(request)
    }

    /// Send a request, throwing on a non-2xx status.
    ///
    /// The thrown body is the **raw** response, not a summary: `WhoopTokenErrorKind`
    /// classifies against it, and reducing it here would discard the `error_hint`
    /// that distinguishes a dead refresh token from a malformed request. The UI
    /// summarises it at display time instead (`errorSummary(from:)`).
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        if (200...299).contains(http.statusCode) { return data }
        throw WhoopServiceError.http(status: http.statusCode,
                                     body: String(data: data, encoding: .utf8) ?? "")
    }

    /// The most specific message in an OAuth error body: `error_hint` if WHOOP
    /// sent one, else `error`, else the raw body. Used for display only.
    static func errorSummary(from raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        let hint = json["error_hint"] as? String
        let code = json["error"] as? String
        switch (code, hint) {
        case let (code?, hint?): return "\(code): \(hint)"
        case let (nil, hint?):   return hint
        case let (code?, nil):   return code
        default:                 return raw
        }
    }

    /// `static` (and so implicitly nonisolated) because it touches no actor state
    /// and must be callable from the `@Sendable` refresh closure.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw WhoopServiceError.decoding }
    }

}
