import AuthenticationServices
import ZonaKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Drives the interactive OAuth authorize leg with `ASWebAuthenticationSession`
/// (the same API on iOS 17 and macOS 14), returning the authorization `code`.
/// Provider-agnostic: the caller supplies the authorize URL and a closure that
/// turns the callback URL into a `Result<code, Error>`, so all provider-specific
/// parsing (Strava's scope check, WHOOP's CSRF `state`) stays in the pure ZonaKit
/// layer. The token exchange itself lives in `StravaService` / `WhoopService`.
///
/// The `@MainActor` + `nonisolated(unsafe)` + `withCheckedThrowingContinuation`
/// mechanics here are hard-won — read the comments before touching them.
@MainActor
final class OAuthAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// The window to anchor the auth sheet to. Set once on the main actor in
    /// `authorize` *before* `session.start()`, then only read — from the
    /// `nonisolated presentationAnchor(for:)` delegate, which AuthenticationServices
    /// may call synchronously on its own XPC queue. That set-before-start /
    /// read-after establishes a happens-before ordering, so the cross-thread read
    /// is safe; `nonisolated(unsafe)` documents that (same pattern as
    /// `SensorMemoryStore`). It must be `nonisolated` because a main-actor-isolated
    /// delegate method invoked synchronously off the main thread trips a dispatch
    /// queue assertion (the EXC_BREAKPOINT in dispatch_assert_queue_fail).
    private nonisolated(unsafe) var anchor: ASPresentationAnchor?

    /// Strong reference to the in-flight session. `ASWebAuthenticationSession`
    /// must be retained for the whole flow; without this the local goes out of
    /// scope after `start()` returns and an early dealloc crashes in the web-auth
    /// XPC teardown. Assigned/cleared only from `nonisolated(unsafe)` context, so
    /// unsafe-marked like `anchor` (the flow is single-shot, no concurrent use).
    private nonisolated(unsafe) var session: ASWebAuthenticationSession?

    /// Present the consent web sheet and resolve with the auth code.
    ///
    /// - Parameters:
    ///   - authorizeURL: the provider's authorize URL (built from a ZonaKit
    ///     `authorizeURL(config:)` helper, including any per-attempt `state`).
    ///   - callbackScheme: the custom redirect scheme registered in Info.plist.
    ///   - parseCallback: maps the redirect URL to the auth code or a typed error;
    ///     wraps the provider's pure `parseCallback` (with `state` already bound).
    ///     Called with `nil` when the session returned no callback URL, so the
    ///     provider can surface its own `.malformedCallback`.
    ///   - cancelledError: thrown when the user dismisses the sheet.
    func authorize(
        authorizeURL: URL,
        callbackScheme: String,
        parseCallback: @escaping @Sendable (URL?) -> Result<String, Error>,
        cancelledError: @autoclosure @escaping @Sendable () -> Error
    ) async throws -> String {
        anchor = Self.currentAnchor()   // resolve the window on the main actor
        defer { session = nil }
        return try await runSession(
            authorizeURL: authorizeURL,
            callbackScheme: callbackScheme,
            parseCallback: parseCallback,
            cancelledError: cancelledError()
        )
    }

    /// Nonisolated so the completion closure below carries no actor isolation. The
    /// completion closure must NOT inherit `@MainActor`: it fires on Authentication
    /// Services' XPC queue, and an isolated closure makes the runtime assert the
    /// executor there and abort (dispatch_assert_queue_fail — the crash). Creating
    /// the closure inside a nonisolated method is what strips the isolation; doing
    /// it in an `@MainActor` method does not.
    private nonisolated func runSession(
        authorizeURL: URL,
        callbackScheme: String,
        parseCallback: @escaping @Sendable (URL?) -> Result<String, Error>,
        cancelledError: Error
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    let code = (error as NSError).code
                    if code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: cancelledError)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(with: parseCallback(callbackURL))
            }
            session.presentationContextProvider = self
            // Reuse an existing web login if the user has one, rather than forcing
            // a fresh sign-in each time.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session   // retain for the duration of the flow
            // ASWebAuthenticationSession.start() must run on the main thread.
            DispatchQueue.main.async { session.start() }
        }
    }

    // `nonisolated`: AuthenticationServices may call this synchronously on its own
    // queue, so it must not require a main-actor hop (that hop is what asserts and
    // crashes). It only reads the anchor already resolved in `authorize`; it never
    // touches UIApplication/NSApplication here.
    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `anchor` is always set on the main actor before `session.start()`, so
        // by the time AuthenticationServices asks for it here it is non-nil.
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
