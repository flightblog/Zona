import AuthenticationServices
import ZonaKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Drives the interactive OAuth authorize leg with `ASWebAuthenticationSession`
/// (the same API on iOS 17 and macOS 14), returning the authorization `code`.
/// The token exchange itself lives in `WhoopService`.
///
/// A near-verbatim clone of `StravaAuthenticator` — the `@MainActor` +
/// `nonisolated(unsafe)` + `withCheckedThrowingContinuation` mechanics are
/// hard-won (see the comments there). The one WHOOP difference: we generate a
/// per-attempt `state` and verify it on the callback (CSRF guard).
@MainActor
final class WhoopAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// The window to anchor the auth sheet to. Set once on the main actor in
    /// `authorize(config:)` *before* `session.start()`, then only read — from the
    /// `nonisolated presentationAnchor(for:)` delegate, which AuthenticationServices
    /// may call synchronously on its own XPC queue. That set-before-start /
    /// read-after establishes a happens-before ordering, so the cross-thread read
    /// is safe; `nonisolated(unsafe)` documents that. It must be `nonisolated`
    /// because a main-actor-isolated delegate method invoked synchronously off the
    /// main thread trips a dispatch queue assertion.
    private nonisolated(unsafe) var anchor: ASPresentationAnchor?

    /// Strong reference to the in-flight session. `ASWebAuthenticationSession`
    /// must be retained for the whole flow; without this the local goes out of
    /// scope after `start()` returns and an early dealloc crashes in the web-auth
    /// XPC teardown. Assigned/cleared only from `nonisolated(unsafe)` context, so
    /// unsafe-marked like `anchor` (the flow is single-shot, no concurrent use).
    private nonisolated(unsafe) var session: ASWebAuthenticationSession?

    /// Present the WHOOP consent web sheet and resolve with the auth code, or
    /// throw a `WhoopAuthError` (`.userCancelled` when dismissed).
    func authorize(config: WhoopOAuthConfig) async throws -> String {
        anchor = Self.currentAnchor()   // resolve the window on the main actor
        // Drive the session from a NONISOLATED context. The completion closure
        // must NOT inherit @MainActor isolation: it fires on Authentication
        // Services' XPC queue, and an isolated closure makes the runtime assert
        // the executor there and abort (dispatch_assert_queue_fail — the crash).
        defer { session = nil }
        return try await runSession(config: config)
    }

    /// Nonisolated so the completion closure below carries no actor isolation.
    private nonisolated func runSession(config: WhoopOAuthConfig) async throws -> String {
        let state = WhoopOAuth.makeState()
        let url = WhoopOAuth.authorizeURL(config: config, state: state)
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: config.redirectScheme
            ) { callbackURL, error in
                if let error {
                    let code = (error as NSError).code
                    if code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: WhoopAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: WhoopAuthError.malformedCallback)
                    return
                }
                continuation.resume(with: WhoopOAuth.parseCallback(callbackURL, expectedState: state))
            }
            session.presentationContextProvider = self
            // Reuse an existing WHOOP web login if the user has one, rather than
            // forcing a fresh sign-in each time.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session   // retain for the duration of the flow
            // ASWebAuthenticationSession.start() must run on the main thread.
            DispatchQueue.main.async { session.start() }
        }
    }

    // `nonisolated`: AuthenticationServices may call this synchronously on its own
    // queue, so it must not require a main-actor hop (that hop is what asserts and
    // crashes). It only reads the anchor already resolved in `authorize(config:)`.
    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor!
    }

    /// Resolve the app's foreground window on the main actor.
    @MainActor
    private static func currentAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
        #elseif os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
