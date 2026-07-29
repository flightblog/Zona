import Foundation
import Testing
@testable import ZonaKit

/// Minimal stand-in for a provider's tokens: a bearer string, the rotating refresh
/// secret, and whether it's expired.
private struct FakeTokens: Codable, Sendable, Equatable {
    var access: String
    var refresh: String
    var expired: Bool
}

/// An in-memory `TokenStore` that records every save, so tests can assert on both
/// the final value and how many writes happened.
private final class SpyTokenStore: TokenStore, @unchecked Sendable {
    typealias Tokens = FakeTokens

    private let lock = NSLock()
    private var stored: FakeTokens?
    private(set) var saves: [FakeTokens] = []

    init(_ initial: FakeTokens?) { stored = initial }

    func loadTokens() -> FakeTokens? {
        lock.withLock { stored }
    }

    func save(_ tokens: FakeTokens) {
        lock.withLock {
            stored = tokens
            saves.append(tokens)
        }
    }

    func clear() {
        lock.withLock { stored = nil }
    }
}

/// Counts refresh invocations across concurrent callers.
private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    /// Records an invocation and returns the new count (1 for the first caller).
    @discardableResult
    func record() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

@Suite("Token refresher")
struct TokenRefresherTests {

    /// Builds a refresher over `store`, delegating the round-trip to `refresh`.
    private func makeRefresher(
        store: SpyTokenStore,
        refresh: @escaping @Sendable (FakeTokens) async throws -> FakeTokens
    ) -> TokenRefresher<FakeTokens> {
        TokenRefresher(store: store,
                       isExpired: { $0.expired },
                       accessToken: { $0.access },
                       refresh: refresh)
    }

    @Test func returnsStoredTokenWhenNotExpired() async throws {
        let store = SpyTokenStore(FakeTokens(access: "live", refresh: "r1", expired: false))
        let refresher = makeRefresher(store: store) { _ in
            Issue.record("should not refresh a valid token")
            return FakeTokens(access: "unused", refresh: "unused", expired: false)
        }

        #expect(try await refresher.validAccessToken() == "live")
        #expect(store.saves.isEmpty)
    }

    @Test func throwsWhenNothingStored() async {
        let store = SpyTokenStore(nil)
        let refresher = makeRefresher(store: store) { _ in
            FakeTokens(access: "unused", refresh: "unused", expired: false)
        }

        await #expect(throws: TokenRefreshError.notAuthorized) {
            _ = try await refresher.validAccessToken()
        }
    }

    @Test func refreshesAndPersistsRotatedToken() async throws {
        let store = SpyTokenStore(FakeTokens(access: "stale", refresh: "r1", expired: true))
        let refresher = makeRefresher(store: store) { current in
            #expect(current.refresh == "r1")
            return FakeTokens(access: "fresh", refresh: "r2", expired: false)
        }

        #expect(try await refresher.validAccessToken() == "fresh")
        // Persisting the rotated refresh token is mandatory — losing it
        // permanently disconnects the account.
        #expect(store.saves.count == 1)
        #expect(store.loadTokens()?.refresh == "r2")
    }

    /// The regression test for the WHOOP 400.
    ///
    /// `fetchZonesAndRecovery` issues two authorized GETs concurrently. With an
    /// expired token both used to reach the refresh endpoint with the *same*
    /// (single-use, rotating) refresh token, so the second got an HTTP 400. Both
    /// callers must instead join one refresh.
    @Test func concurrentCallersShareASingleRefresh() async throws {
        let store = SpyTokenStore(FakeTokens(access: "stale", refresh: "r1", expired: true))
        let counter = RefreshCounter()

        let refresher = makeRefresher(store: store) { current in
            let nth = counter.record()
            // Only the first caller may ever present the rotating secret; a second
            // concurrent refresh is exactly the bug and would 400 in production.
            #expect(nth == 1, "refresh issued \(nth) times — the rotating token would be burned")
            #expect(current.refresh == "r1")
            // Hold the actor across a suspension so a reentrant caller has a real
            // window to slip through, the way a network round-trip does.
            try await Task.sleep(nanoseconds: 20_000_000)
            return FakeTokens(access: "fresh", refresh: "r2", expired: false)
        }

        async let first = refresher.validAccessToken()
        async let second = refresher.validAccessToken()
        let (a, b) = try await (first, second)

        #expect(a == "fresh")
        #expect(b == "fresh")
        #expect(counter.count == 1)
        // One winning writer, so no stale save can clobber the rotated token.
        #expect(store.saves.count == 1)
        #expect(store.loadTokens()?.refresh == "r2")
    }

    @Test func failedRefreshPropagatesToEveryJoinedCaller() async {
        struct RefreshFailure: Error, Equatable {}

        let store = SpyTokenStore(FakeTokens(access: "stale", refresh: "r1", expired: true))
        let counter = RefreshCounter()

        let refresher = makeRefresher(store: store) { _ in
            counter.record()
            try await Task.sleep(nanoseconds: 20_000_000)
            throw RefreshFailure()
        }

        // Explicit tasks rather than `async let`: the latter can't be captured by
        // the `#expect(throws:)` closures below.
        let first = Task { try await refresher.validAccessToken() }
        let second = Task { try await refresher.validAccessToken() }

        await #expect(throws: RefreshFailure.self) { try await first.value }
        await #expect(throws: RefreshFailure.self) { try await second.value }
        #expect(counter.count == 1)
        // A failed refresh must not persist anything.
        #expect(store.saves.isEmpty)
    }

    /// After one refresh settles, the cached task must be cleared so a later
    /// expiry can refresh again rather than replaying the stale result forever.
    @Test func laterExpiryStartsAFreshRefresh() async throws {
        let store = SpyTokenStore(FakeTokens(access: "stale", refresh: "r1", expired: true))
        let counter = RefreshCounter()

        let refresher = makeRefresher(store: store) { current in
            counter.record()
            // Still expired, so the next call refreshes again.
            return FakeTokens(access: "fresh\(current.refresh)", refresh: "r2", expired: true)
        }

        _ = try await refresher.validAccessToken()
        _ = try await refresher.validAccessToken()

        #expect(counter.count == 2)
        #expect(store.saves.count == 2)
    }
}
