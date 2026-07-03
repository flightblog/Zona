import Foundation
import ZonaKit

/// Reads the WHOOP client id/secret injected into Info.plist from the gitignored
/// `Secrets.xcconfig` (see `App/project.yml`). Returns nil when unconfigured, so
/// the UI can hide the WHOOP section on a build without credentials rather than
/// crash or show a dead control.
enum WhoopSecrets {
    /// The OAuth config for this build, or nil if no client id/secret is set.
    static var config: WhoopOAuthConfig? {
        guard let id = infoString("WhoopClientID"),
              let secret = infoString("WhoopClientSecret") else { return nil }
        return WhoopOAuthConfig(clientID: id, clientSecret: secret,
                                redirectScheme: "zona", redirectHost: "whoop-auth")
    }

    /// A non-empty Info.plist string, or nil. Guards against the unsubstituted
    /// `$(WHOOP_CLIENT_ID)` placeholder leaking through when the xcconfig var is
    /// undefined on this machine.
    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
