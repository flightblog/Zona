import AuthenticationServices
import ZonaKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Drives the interactive OAuth authorize leg with `ASWebAuthenticationSession`
/// (the same API on iOS 17 and macOS 14), returning the authorization `code`.
/// The token exchange itself lives in `StravaService`.
@MainActor
final class StravaAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Present the Strava consent web sheet and resolve with the auth code, or
    /// throw a `StravaAuthError` (`.userCancelled` when dismissed).
    func authorize(config: StravaOAuthConfig) async throws -> String {
        let url = StravaOAuth.authorizeURL(config: config)

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: config.redirectScheme
            ) { callbackURL, error in
                if let error {
                    let code = (error as NSError).code
                    if code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: StravaAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: StravaAuthError.malformedCallback)
                    return
                }
                continuation.resume(with: StravaOAuth.parseCallback(callbackURL))
            }
            session.presentationContextProvider = self
            // Reuse an existing Strava web login if the user has one, rather than
            // forcing a fresh sign-in each time.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        // The app's foreground key window.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
        #elseif os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
