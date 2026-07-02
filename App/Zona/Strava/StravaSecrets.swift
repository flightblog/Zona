import Foundation
import ZonaKit

/// Reads the Strava client id/secret injected into Info.plist from the gitignored
/// `Secrets.xcconfig` (see `App/project.yml`). Returns nil when unconfigured, so
/// the UI can hide the Strava button on a build without credentials rather than
/// crash or show a dead control.
enum StravaSecrets {
    /// The OAuth config for this build, or nil if no client id/secret is set.
    static var config: StravaOAuthConfig? {
        guard let id = infoString("StravaClientID"),
              let secret = infoString("StravaClientSecret") else { return nil }
        return StravaOAuthConfig(clientID: id, clientSecret: secret,
                                 redirectScheme: "zona", redirectHost: "strava-auth")
    }

    /// A non-empty Info.plist string, or nil. Guards against the unsubstituted
    /// `$(STRAVA_CLIENT_ID)` placeholder leaking through when the xcconfig var is
    /// undefined on this machine.
    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
