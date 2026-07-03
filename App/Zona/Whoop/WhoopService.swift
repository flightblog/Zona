import Foundation
import ZonaKit

/// Networking errors surfaced to the UI.
enum WhoopServiceError: Error {
    case notAuthorized                       // no tokens stored; must authorize first
    case http(status: Int, body: String)     // non-2xx from WHOOP
    case decoding                            // response didn't decode
    case noRestingHR                         // recovery came back with no scored resting HR
}

/// The networking layer for WHOOP: token exchange, refresh, and the two GETs that
/// supply the HRR-zone inputs (max HR + resting HR). All URL/body/decoding logic
/// is delegated to the pure ZonaKit helpers (`WhoopOAuth`, `WhoopTokens`,
/// `WhoopBodyMeasurement`, `WhoopRecoveryPage`); this actor only does the I/O.
///
/// An `actor` so a token refresh is serialized — two concurrent fetches can't
/// both refresh and clobber each other's rotated refresh token (matches
/// `StravaService`).
actor WhoopService {
    private let config: WhoopOAuthConfig
    private let tokens: WhoopTokenStore
    private let session: URLSession

    private static let apiBase = URL(string: "https://api.prod.whoop.com/developer")!

    init(config: WhoopOAuthConfig, tokens: WhoopTokenStore, session: URLSession = .shared) {
        self.config = config
        self.tokens = tokens
        self.session = session
    }

    var isConnected: Bool { tokens.loadTokens() != nil }

    func disconnect() { tokens.clear() }

    // MARK: OAuth

    /// Exchange an authorization `code` (from ASWebAuthenticationSession) for
    /// tokens and persist them.
    @discardableResult
    func exchange(code: String) async throws -> WhoopTokens {
        let body = WhoopOAuth.tokenExchangeBody(code: code, config: config)
        let response = try await postForm(WhoopOAuth.tokenURL, fields: body, accessToken: nil)
        let decoded = try decode(WhoopTokenResponse.self, from: response)
        let newTokens = WhoopTokens(from: decoded)
        tokens.save(newTokens)
        return newTokens
    }

    /// A currently-valid access token, refreshing first if the cached one is at
    /// or near expiry. Persists the rotated refresh token.
    func validAccessToken() async throws -> String {
        guard let current = tokens.loadTokens() else { throw WhoopServiceError.notAuthorized }
        guard current.isExpired() else { return current.accessToken }

        let body = WhoopOAuth.refreshBody(refreshToken: current.refreshToken, config: config)
        let response = try await postForm(WhoopOAuth.tokenURL, fields: body, accessToken: nil)
        let decoded = try decode(WhoopTokenResponse.self, from: response)
        let refreshed = WhoopTokens(from: decoded)
        tokens.save(refreshed)   // refresh token rotated — persisting is mandatory
        return refreshed.accessToken
    }

    // MARK: Zone inputs

    /// The two numbers WHOOP derives its HR zones from: max HR (body measurement)
    /// and resting HR (latest scored recovery). One combined call so the UI has a
    /// single "refresh zones" action.
    func fetchZoneInputs() async throws -> (maxHR: Int, restingHR: Int) {
        async let maxHR = fetchMaxHR()
        async let restingHR = fetchRestingHR()
        return try await (maxHR, restingHR)
    }

    /// `GET /v2/user/measurement/body` → max heart rate.
    func fetchMaxHR() async throws -> Int {
        let url = Self.apiBase.appendingPathComponent("v2/user/measurement/body")
        let data = try await authorizedGet(url)
        return try decode(WhoopBodyMeasurement.self, from: data).maxHeartRate
    }

    /// `GET /v2/recovery` (newest first) → resting HR from the latest scored
    /// record. `limit=10` gives headroom to skip a still-calibrating top record.
    func fetchRestingHR() async throws -> Int {
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent("v2/recovery"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: "10")]
        let data = try await authorizedGet(comps.url!)
        guard let rhr = try decode(WhoopRecoveryPage.self, from: data).latestRestingHR else {
            throw WhoopServiceError.noRestingHR
        }
        return rhr
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
        request.httpBody = fields
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await send(request)
    }

    /// Send a request, throwing on a non-2xx status.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        if (200...299).contains(http.statusCode) { return data }
        throw WhoopServiceError.http(status: http.statusCode,
                                     body: String(data: data, encoding: .utf8) ?? "")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw WhoopServiceError.decoding }
    }

    private func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
