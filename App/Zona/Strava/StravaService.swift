import Foundation
import ZonaKit

/// Networking errors surfaced to the UI.
enum StravaServiceError: Error {
    case notAuthorized                       // no tokens stored; must authorize first
    case http(status: Int, body: String)     // non-2xx from Strava
    case decoding                            // response didn't decode
    case uploadTimedOut                      // polled to the cap without a terminal state
}

/// The networking layer for Strava: token exchange, refresh, and the TCX
/// upload + status poll. All URL/body/decoding logic is delegated to the pure
/// ZonaKit helpers (`StravaOAuth`, `StravaTokens`, `StravaUploadPoll`); this
/// actor only does the actual I/O.
///
/// An `actor` so a token refresh is serialized — two concurrent uploads can't
/// both refresh and clobber each other's rotated refresh token.
actor StravaService {
    private let config: StravaOAuthConfig
    private let tokens: TokenStore
    private let session: URLSession

    init(config: StravaOAuthConfig, tokens: TokenStore, session: URLSession = .shared) {
        self.config = config
        self.tokens = tokens
        self.session = session
    }

    var isConnected: Bool { tokens.loadTokens() != nil }

    func disconnect() { tokens.clear() }

    // MARK: OAuth

    /// Exchange an authorization `code` (from ASWebAuthenticationSession) for
    /// tokens and persist them.
    func exchange(code: String) async throws -> StravaTokens {
        let body = StravaOAuth.tokenExchangeBody(code: code, config: config)
        let response = try await postForm(StravaOAuth.tokenURL, fields: body, accessToken: nil)
        let decoded = try decode(StravaTokenResponse.self, from: response)
        let newTokens = StravaTokens(from: decoded)
        tokens.save(newTokens)
        return newTokens
    }

    /// A currently-valid access token, refreshing first if the cached one is at
    /// or near expiry. Persists the rotated refresh token.
    func validAccessToken() async throws -> String {
        guard let current = tokens.loadTokens() else { throw StravaServiceError.notAuthorized }
        guard current.isExpired() else { return current.accessToken }

        let body = StravaOAuth.refreshBody(refreshToken: current.refreshToken, config: config)
        let response = try await postForm(StravaOAuth.tokenURL, fields: body, accessToken: nil)
        let decoded = try decode(StravaTokenResponse.self, from: response)
        let refreshed = StravaTokens(from: decoded)
        tokens.save(refreshed)   // refresh token rotated — persisting is mandatory
        return refreshed.accessToken
    }

    // MARK: Upload

    /// Upload a TCX document and poll until Strava reaches a terminal state.
    /// `filenameBase` is the multipart filename without extension (e.g.
    /// `Zona-2026-07-01-0730`). `activityName` becomes the Strava activity title.
    func upload(tcx: String, filenameBase: String, activityName: String) async throws -> StravaUploadOutcome {
        let token = try await validAccessToken()
        let uploadsURL = URL(string: "https://www.strava.com/api/v3/uploads")!
        let filename = StravaUploadPoll.multipartFilename(for: filenameBase)

        let (body, contentType) = multipartBody(
            tcx: tcx, filename: filename, dataType: StravaUploadPoll.dataType, name: activityName)
        var request = URLRequest(url: uploadsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let initial = try await send(request)
        var status = try decode(StravaUploadStatus.self, from: initial)
        var outcome = StravaUploadPoll.outcome(for: status)

        // Poll GET /uploads/{id} ~1s until terminal or the cap. Strava's mean
        // processing time is under 2s, so ~30 tries is generous.
        var attempts = 0
        while outcome == .pending, attempts < 30 {
            try await Task.sleep(for: .seconds(1))
            attempts += 1
            let statusURL = uploadsURL.appendingPathComponent(String(status.id))
            var poll = URLRequest(url: statusURL)
            poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            status = try decode(StravaUploadStatus.self, from: try await send(poll))
            outcome = StravaUploadPoll.outcome(for: status)
        }

        if outcome == .pending { throw StravaServiceError.uploadTimedOut }
        return outcome
    }

    // MARK: HTTP plumbing

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

    /// Send a request, throwing on a non-2xx status. Strava's upload endpoint
    /// returns the upload body even on a 4xx duplicate, so we let the *body*
    /// (parsed by StravaUploadPoll) decide duplicate vs failure — but a token
    /// endpoint 4xx is a hard error.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        // 2xx: fine. For /uploads, a 4xx still carries a JSON body with an `error`
        // string (duplicates), which the caller interprets — so pass those through.
        if (200...299).contains(http.statusCode) { return data }
        if request.url?.path.contains("/uploads") == true, (400...499).contains(http.statusCode) {
            return data
        }
        throw StravaServiceError.http(status: http.statusCode,
                                      body: String(data: data, encoding: .utf8) ?? "")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw StravaServiceError.decoding }
    }

    /// Build a `multipart/form-data` body with the TCX file + `data_type` field.
    /// Also sets the activity `name` and flags the upload as a `trainer`
    /// activity — every Zona ride is an indoor trainer session.
    private func multipartBody(tcx: String, filename: String, dataType: String, name: String) -> (Data, String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }

        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        field("data_type", dataType)
        field("name", name)
        field("trainer", "1")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        append(tcx)
        append("\r\n")

        append("--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
