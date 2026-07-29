import Foundation

/// Single-flight OAuth access-token refresh, shared by every provider.
///
/// The problem this exists to solve: an `actor` does **not** by itself serialize a
/// refresh. Actor isolation guarantees mutual exclusion only across *synchronous*
/// regions — at every `await` the actor is released and another call can enter. So
/// the natural shape
///
/// ```swift
/// guard current.isExpired() else { return current.accessToken }
/// let refreshed = try await post(refreshBody)   // <- suspends, actor released
/// tokens.save(refreshed)
/// ```
///
/// lets two concurrent callers both observe the *same* expired token, both POST the
/// *same* refresh token, and both `save()`. Providers that rotate the refresh token
/// on every use (WHOOP and Strava both do) invalidate the old one the moment the
/// first request lands, so the second gets an HTTP 400 — and whichever save lands
/// last can overwrite the good rotated token with a stale one, which makes the
/// failure sticky across retries rather than clearing on the next attempt.
///
/// WHOOP documents this directly: when multiple refresh requests occur
/// simultaneously, only the first succeeds.
///
/// The fix is to cache the in-flight `Task` and have later callers `await` it
/// instead of starting their own. The cache is written *before* the first
/// suspension point, which is what closes the reentrancy window.
///
/// Pure by construction: the actual network POST arrives as a `Sendable` closure,
/// so this is fully testable in ZonaKit without `URLSession`, while the app target
/// keeps the I/O (mirrors how `StravaUpload` models the upload without performing
/// it).
public actor TokenRefresher<Tokens: Codable & Sendable> {
    /// Performs the provider's refresh round-trip for `tokens`, returning the newly
    /// issued tokens. Throws to propagate to every joined caller.
    public typealias Refresh = @Sendable (Tokens) async throws -> Tokens

    private let store: any TokenStore<Tokens>
    private let isExpired: @Sendable (Tokens) -> Bool
    private let accessToken: @Sendable (Tokens) -> String
    private let refresh: Refresh

    /// The refresh currently in flight, if any. Callers that arrive while this is
    /// non-nil join it rather than issuing a second refresh.
    private var inFlight: Task<Tokens, Error>?

    /// - Parameters:
    ///   - store: where tokens are persisted. The rotated token is saved here on
    ///     success; a lost save permanently disconnects the account.
    ///   - isExpired: whether the stored access token needs refreshing (providers
    ///     apply their own leeway).
    ///   - accessToken: pulls the bearer string out of the token type.
    ///   - refresh: performs the network round-trip.
    public init(store: any TokenStore<Tokens>,
                isExpired: @escaping @Sendable (Tokens) -> Bool,
                accessToken: @escaping @Sendable (Tokens) -> String,
                refresh: @escaping Refresh) {
        self.store = store
        self.isExpired = isExpired
        self.accessToken = accessToken
        self.refresh = refresh
    }

    /// A currently-valid access token, refreshing first if the stored one is at or
    /// near expiry. Concurrent callers that arrive during a refresh await the same
    /// one and all receive its result.
    ///
    /// - Throws: `TokenRefreshError.notAuthorized` when nothing is stored, or
    ///   whatever `refresh` throws.
    public func validAccessToken() async throws -> String {
        guard let current = store.loadTokens() else { throw TokenRefreshError.notAuthorized }
        guard isExpired(current) else { return accessToken(current) }
        return accessToken(try await refreshed(from: current))
    }

    /// Join the in-flight refresh, or start one. Assigning `inFlight` happens before
    /// any `await`, so a second caller entering this actor always observes it.
    private func refreshed(from current: Tokens) async throws -> Tokens {
        if let inFlight { return try await inFlight.value }

        let task = Task<Tokens, Error> { [refresh] in
            try await refresh(current)
        }
        inFlight = task

        defer { inFlight = nil }
        let new = try await task.value
        // Saved by the single winning refresh only — no racing writer can clobber
        // the rotated token with a stale one.
        store.save(new)
        return new
    }
}

/// Failure modes common to every provider's refresh.
public enum TokenRefreshError: Error, Equatable, Sendable {
    /// No tokens stored — the user has never connected, or disconnected.
    case notAuthorized
}
