import Foundation
import Testing
@testable import ZonaKit

@Suite("WHOOP OAuth")
struct WhoopOAuthTests {
    private var config: WhoopOAuthConfig {
        WhoopOAuthConfig(clientID: "cid", clientSecret: "shh",
                         redirectScheme: "zona", redirectHost: "whoop-auth")
    }

    @Test func authorizeURLCarriesExpectedParams() throws {
        let url = WhoopOAuth.authorizeURL(config: config, state: "state123")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(url.absoluteString.hasPrefix("https://api.prod.whoop.com/oauth/oauth2/auth"))
        #expect(items["client_id"] == "cid")
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "read:body_measurement read:recovery offline")
        #expect(items["redirect_uri"] == "zona://whoop-auth")
        #expect(items["state"] == "state123")
    }

    @Test func redirectURIComposesSchemeAndHost() {
        #expect(config.redirectURI == "zona://whoop-auth")
    }

    @Test func makeStateIsLongEnough() {
        // WHOOP requires state ≥ 8 chars.
        #expect(WhoopOAuth.makeState().count >= 8)
    }

    @Test func parseCallbackExtractsCode() throws {
        let url = URL(string: "zona://whoop-auth?code=abc123&state=st8")!
        #expect(try WhoopOAuth.parseCallback(url, expectedState: "st8").get() == "abc123")
    }

    @Test func parseCallbackStateMismatchRejected() {
        let url = URL(string: "zona://whoop-auth?code=abc123&state=WRONG")!
        #expect(WhoopOAuth.parseCallback(url, expectedState: "st8") == .failure(.stateMismatch))
    }

    @Test func parseCallbackAccessDenied() {
        // Denial is checked before state so a declining user gets the right error.
        let url = URL(string: "zona://whoop-auth?error=access_denied&state=st8")!
        #expect(WhoopOAuth.parseCallback(url, expectedState: "st8") == .failure(.accessDenied))
    }

    @Test func parseCallbackMissingCode() {
        let url = URL(string: "zona://whoop-auth?state=st8")!
        #expect(WhoopOAuth.parseCallback(url, expectedState: "st8") == .failure(.missingCode))
    }

    @Test func tokenExchangeBodyHasAuthCodeGrant() {
        let body = WhoopOAuth.tokenExchangeBody(code: "abc", config: config)
        #expect(body["grant_type"] == "authorization_code")
        #expect(body["code"] == "abc")
        #expect(body["client_id"] == "cid")
        #expect(body["client_secret"] == "shh")
        #expect(body["redirect_uri"] == "zona://whoop-auth")
    }

    @Test func refreshBodyHasRefreshGrant() {
        let body = WhoopOAuth.refreshBody(refreshToken: "r3fr3sh", config: config)
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["refresh_token"] == "r3fr3sh")
        #expect(body["client_id"] == "cid")
        #expect(body["client_secret"] == "shh")
        #expect(body["scope"] == "offline")
    }
}

@Suite("WHOOP tokens")
struct WhoopTokenTests {
    @Test func decodesSnakeCaseResponse() throws {
        let json = """
        {"access_token":"acc355","refresh_token":"r3fr3sh","expires_in":3600,
         "token_type":"bearer","scope":"read:recovery offline"}
        """
        let resp = try JSONDecoder().decode(WhoopTokenResponse.self, from: Data(json.utf8))
        #expect(resp.accessToken == "acc355")
        #expect(resp.refreshToken == "r3fr3sh")
        #expect(resp.expiresIn == 3600)
        #expect(resp.scope == "read:recovery offline")
    }

    @Test func mapsExpiresInToAbsoluteDate() throws {
        let resp = try JSONDecoder().decode(
            WhoopTokenResponse.self,
            from: Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"bearer"}"#.utf8))
        let now = Date(timeIntervalSince1970: 1000)
        let tokens = WhoopTokens(from: resp, now: now)
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 4600))
    }

    @Test func isExpiredWithinLeeway() {
        let expiry = Date(timeIntervalSince1970: 10_000)
        let tokens = WhoopTokens(accessToken: "a", refreshToken: "r", expiresAt: expiry)
        // 200s before expiry, 120s leeway → not yet expired.
        #expect(tokens.isExpired(now: expiry.addingTimeInterval(-200), leeway: 120) == false)
        // 60s before expiry, 120s leeway → treat as expired (refresh early).
        #expect(tokens.isExpired(now: expiry.addingTimeInterval(-60), leeway: 120) == true)
    }
}

@Suite("WHOOP DTOs")
struct WhoopDTOTests {
    @Test func decodesBodyMeasurement() throws {
        let json = #"{"height_meter":1.8288,"weight_kilogram":90.7185,"max_heart_rate":198}"#
        let body = try JSONDecoder().decode(WhoopBodyMeasurement.self, from: Data(json.utf8))
        #expect(body.maxHeartRate == 198)
        #expect(body.heightMeter == 1.8288)
    }

    @Test func decodesRecoveryPageAndPicksLatestRestingHR() throws {
        // Records are sorted newest-first; latestRestingHR takes the first scored one.
        let json = """
        {"records":[
          {"score":{"user_calibrating":false,"recovery_score":66,"resting_heart_rate":48.0,"hrv_rmssd_milli":42.5}},
          {"score":{"user_calibrating":false,"recovery_score":70,"resting_heart_rate":50.0,"hrv_rmssd_milli":40.0}}
        ],"next_token":"tok"}
        """
        let page = try JSONDecoder().decode(WhoopRecoveryPage.self, from: Data(json.utf8))
        #expect(page.records.count == 2)
        #expect(page.nextToken == "tok")
        #expect(page.latestRestingHR == 48)
    }

    @Test func latestRestingHRSkipsUnscoredRecords() throws {
        // A still-calibrating record has no score; fall through to the next.
        let json = """
        {"records":[
          {"score":null},
          {"score":{"resting_heart_rate":52.4,"hrv_rmssd_milli":30.0}}
        ]}
        """
        let page = try JSONDecoder().decode(WhoopRecoveryPage.self, from: Data(json.utf8))
        #expect(page.latestRestingHR == 52)
    }

    @Test func latestRestingHRNilWhenAllUnscored() throws {
        let page = try JSONDecoder().decode(
            WhoopRecoveryPage.self,
            from: Data(#"{"records":[{"score":null}]}"#.utf8))
        #expect(page.latestRestingHR == nil)
    }

    @Test func latestRecoverySurfacesAllRoundedFields() throws {
        let json = """
        {"records":[
          {"score":{"recovery_score":66.4,"resting_heart_rate":48.6,"hrv_rmssd_milli":42.5}}
        ]}
        """
        let page = try JSONDecoder().decode(WhoopRecoveryPage.self, from: Data(json.utf8))
        let rec = page.latestRecovery
        #expect(rec?.recoveryScore == 66)
        #expect(rec?.restingHR == 49)
        #expect(rec?.hrvMs == 43)
    }

    @Test func latestRecoveryNilWhenUnscored() throws {
        let page = try JSONDecoder().decode(
            WhoopRecoveryPage.self,
            from: Data(#"{"records":[{"score":null}]}"#.utf8))
        #expect(page.latestRecovery == nil)
    }
}

@Suite("WHOOP readiness")
struct WhoopReadinessTests {
    @Test func bandThresholdsMatchWhoopColors() {
        #expect(WhoopRecoveryBand(recoveryScore: 90) == .green)
        #expect(WhoopRecoveryBand(recoveryScore: 67) == .green)   // green floor
        #expect(WhoopRecoveryBand(recoveryScore: 66) == .yellow)
        #expect(WhoopRecoveryBand(recoveryScore: 34) == .yellow)  // yellow floor
        #expect(WhoopRecoveryBand(recoveryScore: 33) == .red)
        #expect(WhoopRecoveryBand(recoveryScore: 0) == .red)
    }

    @Test func greenSuggestsTempoCeiling() {
        let r = WhoopReadiness(recoveryScore: 80)
        #expect(r?.band == .green)
        #expect(r?.suggestedCeiling == .z3)
    }

    @Test func yellowSuggestsZ2() {
        let r = WhoopReadiness(recoveryScore: 50)
        #expect(r?.band == .yellow)
        #expect(r?.suggestedCeiling == .z2)
    }

    @Test func redSuggestsRecoverySpin() {
        let r = WhoopReadiness(recoveryScore: 20)
        #expect(r?.band == .red)
        #expect(r?.suggestedCeiling == .z1)
        #expect(r?.message.isEmpty == false)
    }

    @Test func nilScoreYieldsNoAdvice() {
        #expect(WhoopReadiness(recoveryScore: nil) == nil)
    }

    @Test func buildsFromRecoverySnapshot() {
        let rec = WhoopRecovery(recoveryScore: 75, hrvMs: 55, restingHR: 47)
        #expect(WhoopReadiness(from: rec)?.suggestedCeiling == .z3)
    }
}

@Suite("WHOOP token error classification")
struct WhoopTokenErrorKindTests {

    /// The exact body WHOOP returns for a refresh token it will not honour —
    /// captured from the live endpoint. Note it is `invalid_request`, *not* the
    /// standard `invalid_grant`, which is why the hint has to be matched.
    private static let deadTokenBody = """
    {"error":"invalid_request","error_description":"The request is missing a required parameter, \
    includes an invalid parameter value, includes a parameter more than once, or is otherwise \
    malformed","error_hint":"Make sure that the various parameters are correct, be aware of case \
    sensitivity and trim your parameters. Make sure that the client you are using has exactly \
    whitelisted the redirect_uri you specified.","status_code":400}
    """

    /// A genuinely malformed request: same `error` code, different hint.
    private static let missingParamBody = """
    {"error":"invalid_request","error_description":"The request is missing a required parameter, \
    includes an invalid parameter value, includes a parameter more than once, or is otherwise \
    malformed","error_hint":"Request parameter \\"grant_type\\"\\" is missing","status_code":400}
    """

    private static let badClientBody = """
    {"error":"invalid_client","error_description":"Client authentication failed","status_code":401}
    """

    @Test func deadRefreshTokenIsRecognised() {
        #expect(WhoopTokenErrorKind.classify(body: Self.deadTokenBody, grantType: "refresh_token")
                == .deadRefreshToken)
    }

    /// A missing `grant_type` is a bug in our request, not a dead token — clearing
    /// the user's credentials over it would be wrong.
    @Test func missingParameterIsNotADeadToken() {
        #expect(WhoopTokenErrorKind.classify(body: Self.missingParamBody, grantType: "refresh_token")
                == .other)
    }

    @Test func badClientIsNotADeadToken() {
        #expect(WhoopTokenErrorKind.classify(body: Self.badClientBody, grantType: "refresh_token")
                == .other)
    }

    /// Standard OAuth2 `invalid_grant`, in case WHOOP ever starts using it.
    @Test func standardInvalidGrantIsRecognised() {
        let body = #"{"error":"invalid_grant","error_description":"token expired"}"#
        #expect(WhoopTokenErrorKind.classify(body: body, grantType: "refresh_token")
                == .deadRefreshToken)
    }

    /// Only a refresh grant can produce a dead *refresh* token. The same hint on an
    /// authorization-code exchange means our request was wrong, and reconnecting
    /// wouldn't fix it — so it must not send the user round that loop.
    @Test func authorizationCodeGrantIsNeverADeadRefreshToken() {
        #expect(WhoopTokenErrorKind.classify(body: Self.deadTokenBody, grantType: "authorization_code")
                == .other)
    }

    @Test func emptyBodyIsNotADeadToken() {
        #expect(WhoopTokenErrorKind.classify(body: "", grantType: "refresh_token") == .other)
    }
}
