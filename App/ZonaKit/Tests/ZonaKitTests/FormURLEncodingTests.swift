import Foundation
import Testing
@testable import ZonaKit

@Suite("Form URL encoding")
struct FormURLEncodingTests {

    /// The regression test for the WHOOP `invalid_request` 400.
    ///
    /// Encoding with `.alphanumerics` escaped the underscore, putting
    /// `grant_type=refresh%5Ftoken` on the wire instead of `refresh_token`.
    @Test func underscoresSurviveInGrantType() {
        #expect(FormURLEncoding.escape("refresh_token") == "refresh_token")
        #expect(FormURLEncoding.escape("authorization_code") == "authorization_code")
    }

    /// RFC 3986 unreserved characters must be left literal. Refresh tokens and
    /// JWT-ish credentials routinely contain `-`, `.` and `_`, so escaping these
    /// corrupts the secret itself.
    @Test func unreservedCharactersAreNotEscaped() {
        #expect(FormURLEncoding.escape("abc.def-ghi_jkl~mno") == "abc.def-ghi_jkl~mno")
        #expect(FormURLEncoding.escape("AZaz09") == "AZaz09")
    }

    /// Everything outside the unreserved set still has to be escaped — otherwise a
    /// value containing `&` or `=` would forge extra form fields.
    @Test func reservedCharactersAreEscaped() {
        #expect(FormURLEncoding.escape("a b") == "a%20b")
        #expect(FormURLEncoding.escape("a&b") == "a%26b")
        #expect(FormURLEncoding.escape("a=b") == "a%3Db")
        #expect(FormURLEncoding.escape("a:b") == "a%3Ab")
        #expect(FormURLEncoding.escape("a/b") == "a%2Fb")
    }

    /// `+` means "space" when a form body is decoded, so a literal `+` in a
    /// base64-ish token must be escaped or it silently becomes a space.
    @Test func plusIsEscapedNotTreatedAsSpace() {
        #expect(FormURLEncoding.escape("a+b/c=") == "a%2Bb%2Fc%3D")
    }

    /// The scope value WHOOP requires on refresh, and the space-separated one sent
    /// on the initial authorize exchange.
    @Test func scopeValuesEncodeCorrectly() {
        #expect(FormURLEncoding.escape("offline") == "offline")
        #expect(FormURLEncoding.escape("read:body_measurement read:recovery offline")
                == "read%3Abody_measurement%20read%3Arecovery%20offline")
    }

    @Test func bodyJoinsFieldsWithAmpersand() {
        let body = FormURLEncoding.body(["grant_type": "refresh_token", "client_id": "42"])
        #expect(body == "client_id=42&grant_type=refresh_token")
    }

    /// Dictionary iteration order varies per process, so the body is sorted by key
    /// to stay reproducible.
    @Test func bodyIsDeterministicallyOrdered() {
        let fields = ["z": "1", "a": "2", "m": "3"]
        #expect(FormURLEncoding.body(fields) == "a=2&m=3&z=1")
        #expect(FormURLEncoding.body(fields) == FormURLEncoding.body(fields))
    }

    @Test func emptyFieldsProduceEmptyBody() {
        #expect(FormURLEncoding.body([:]) == "")
        #expect(FormURLEncoding.bodyData([:]).isEmpty)
    }

    @Test func bodyDataIsUTF8OfBody() {
        let fields = ["grant_type": "refresh_token", "scope": "offline"]
        #expect(FormURLEncoding.bodyData(fields) == Data(FormURLEncoding.body(fields).utf8))
    }

    /// A full refresh body, end to end — the exact request that was 400ing.
    @Test func refreshBodyRoundTripsThroughURLComponents() throws {
        let fields = WhoopOAuth.refreshBody(
            refreshToken: "rt.abc-123_XYZ~tilde",
            config: WhoopOAuthConfig(clientID: "cid-1", clientSecret: "sec_2",
                                     redirectScheme: "zona", redirectHost: "whoop-auth"))
        let body = FormURLEncoding.body(fields)

        // Decode the way a server does and confirm every value arrives intact.
        var comps = URLComponents()
        comps.percentEncodedQuery = body
        let decoded = Dictionary(uniqueKeysWithValues:
            (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(decoded["grant_type"] == "refresh_token")
        #expect(decoded["refresh_token"] == "rt.abc-123_XYZ~tilde")
        #expect(decoded["client_id"] == "cid-1")
        #expect(decoded["client_secret"] == "sec_2")
        #expect(decoded["scope"] == "offline")
    }
}
