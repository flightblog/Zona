import Foundation
import Testing
@testable import ZonaKit

@Suite("Strava OAuth")
struct StravaOAuthTests {
    private var config: StravaOAuthConfig {
        StravaOAuthConfig(clientID: "12345", clientSecret: "shh",
                          redirectScheme: "zona", redirectHost: "strava-auth")
    }

    @Test func authorizeURLCarriesExpectedParams() throws {
        let url = StravaOAuth.authorizeURL(config: config)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(url.absoluteString.hasPrefix("https://www.strava.com/oauth/mobile/authorize"))
        #expect(items["client_id"] == "12345")
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "activity:write")
        #expect(items["redirect_uri"] == "zona://strava-auth")
    }

    @Test func redirectURIComposesSchemeAndHost() {
        #expect(config.redirectURI == "zona://strava-auth")
    }

    @Test func parseCallbackExtractsCode() throws {
        let url = URL(string: "zona://strava-auth?state=&code=abc123&scope=read,activity:write")!
        #expect(try StravaOAuth.parseCallback(url).get() == "abc123")
    }

    @Test func parseCallbackAccessDenied() {
        let url = URL(string: "zona://strava-auth?error=access_denied")!
        #expect(StravaOAuth.parseCallback(url) == .failure(.accessDenied))
    }

    @Test func parseCallbackMissingCode() {
        let url = URL(string: "zona://strava-auth?scope=activity:write")!
        #expect(StravaOAuth.parseCallback(url) == .failure(.missingCode))
    }

    @Test func parseCallbackMissingScopeRejected() {
        // Code present but the user only granted `read` — uploads would fail.
        let url = URL(string: "zona://strava-auth?code=abc123&scope=read")!
        #expect(StravaOAuth.parseCallback(url) == .failure(.missingScope))
    }

    @Test func tokenExchangeBodyHasAuthCodeGrant() {
        let body = StravaOAuth.tokenExchangeBody(code: "abc", config: config)
        #expect(body["grant_type"] == "authorization_code")
        #expect(body["code"] == "abc")
        #expect(body["client_id"] == "12345")
        #expect(body["client_secret"] == "shh")
    }

    @Test func refreshBodyHasRefreshGrant() {
        let body = StravaOAuth.refreshBody(refreshToken: "r3fr3sh", config: config)
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["refresh_token"] == "r3fr3sh")
        #expect(body["client_id"] == "12345")
        #expect(body["client_secret"] == "shh")
    }
}

@Suite("Strava tokens")
struct StravaTokenTests {
    @Test func decodesSnakeCaseResponse() throws {
        let json = """
        {"token_type":"Bearer","expires_at":1900000000,"expires_in":21600,
         "refresh_token":"r3fr3sh","access_token":"acc355"}
        """
        let resp = try JSONDecoder().decode(StravaTokenResponse.self, from: Data(json.utf8))
        #expect(resp.accessToken == "acc355")
        #expect(resp.refreshToken == "r3fr3sh")
        #expect(resp.expiresAt == 1_900_000_000)
        #expect(resp.tokenType == "Bearer")
    }

    @Test func mapsExpiryToDate() throws {
        let resp = try JSONDecoder().decode(
            StravaTokenResponse.self,
            from: Data(#"{"token_type":"Bearer","expires_at":1000,"refresh_token":"r","access_token":"a"}"#.utf8))
        let tokens = StravaTokens(from: resp)
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 1000))
    }

    @Test func isExpiredWithinLeeway() {
        let expiry = Date(timeIntervalSince1970: 10_000)
        let tokens = StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: expiry)
        // 400s before expiry, 300s leeway → not yet expired.
        #expect(tokens.isExpired(now: expiry.addingTimeInterval(-400), leeway: 300) == false)
        // 200s before expiry, 300s leeway → treat as expired (refresh early).
        #expect(tokens.isExpired(now: expiry.addingTimeInterval(-200), leeway: 300) == true)
        // Exactly at expiry → expired.
        #expect(tokens.isExpired(now: expiry, leeway: 0) == true)
    }
}

@Suite("Strava upload poll")
struct StravaUploadPollTests {
    @Test func succeededWhenActivityIdPresent() {
        let s = StravaUploadStatus(id: 1, status: "Your activity is ready.", activityId: 999)
        #expect(StravaUploadPoll.outcome(for: s) == .succeeded(activityId: 999))
    }

    @Test func pendingWhenNoIdAndNoError() {
        let s = StravaUploadStatus(id: 1, status: "Your activity is still being processed.")
        #expect(StravaUploadPoll.outcome(for: s) == .pending)
    }

    @Test func duplicateWithId() {
        let s = StravaUploadStatus(id: 1, error: "duplicate of activity 123456")
        #expect(StravaUploadPoll.outcome(for: s) == .duplicate(activityId: 123456))
    }

    @Test func duplicateWithoutParsableId() {
        let s = StravaUploadStatus(id: 1, error: "This activity is a duplicate.")
        #expect(StravaUploadPoll.outcome(for: s) == .duplicate(activityId: nil))
    }

    @Test func plainFailure() {
        let s = StravaUploadStatus(id: 1, error: "There was an error processing your activity.")
        #expect(StravaUploadPoll.outcome(for: s) == .failed(message: "There was an error processing your activity."))
    }

    @Test func multipartConstants() {
        #expect(StravaUploadPoll.dataType == "tcx")
        #expect(StravaUploadPoll.multipartFilename(for: "Zona-2026-07-01-0730") == "Zona-2026-07-01-0730.tcx")
    }

    @Test func activityURL() {
        #expect(stravaActivityURL(123456).absoluteString == "https://www.strava.com/activities/123456")
    }

    @Test func decodesUploadStatusJSON() throws {
        let json = #"{"id":42,"id_str":"42","error":null,"status":"Your activity is ready.","activity_id":777}"#
        let s = try JSONDecoder().decode(StravaUploadStatus.self, from: Data(json.utf8))
        #expect(s.id == 42)
        #expect(s.activityId == 777)
        #expect(s.error == nil)
        #expect(StravaUploadPoll.outcome(for: s) == .succeeded(activityId: 777))
    }
}
