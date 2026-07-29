import Foundation

/// Builds `application/x-www-form-urlencoded` request bodies — the encoding both
/// OAuth token endpoints (Strava, WHOOP) expect.
///
/// This exists because getting the allowed character set wrong is easy and the
/// failure is invisible on the wire. Encoding with `.alphanumerics` looks safely
/// conservative but is actually **malformed**: RFC 3986's unreserved characters
/// (`A-Z a-z 0-9 - . _ ~`) must be left literal. Escaping them too turned
/// `grant_type` into `refresh%5Ftoken` and corrupted any refresh token containing
/// `-`, `.` or `_` — which WHOOP rejected with
/// `invalid_request: ... includes an invalid parameter value`.
///
/// Pure and in `ZonaKit` so the encoding is unit-tested rather than duplicated
/// (and re-broken) in each app-target service.
public enum FormURLEncoding {

    /// RFC 3986 unreserved characters: the only ones that stay literal. Everything
    /// else — including `+`, `/`, `=`, `:` and space — is percent-escaped.
    public static let unreserved: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// Percent-encode a single key or value. Space becomes `%20`; `+` is escaped to
    /// `%2B` rather than being treated as a space, so a token containing `+`
    /// survives the round-trip.
    public static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Encode `fields` into a form body.
    ///
    /// Keys are sorted so the body is deterministic — `Dictionary` iteration order
    /// varies per process, which would otherwise make the request unreproducible
    /// and this untestable.
    public static func body(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    /// `body(_:)` as UTF-8 bytes, ready for `URLRequest.httpBody`.
    public static func bodyData(_ fields: [String: String]) -> Data {
        Data(body(fields).utf8)
    }
}
