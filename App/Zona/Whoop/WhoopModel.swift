import Foundation
import SwiftUI
import ZonaKit

/// Where the WHOOP connection sits, driving the setup-screen section.
enum WhoopConnectionState: Equatable {
    case unavailable                       // no client id/secret configured on this build
    case disconnected                      // configured but not yet authorized
    case authorizing
    case connected                         // tokens present
    case refreshing                        // fetching zone inputs
    case failed(message: String)
}

/// Drives the WHOOP integration from the setup screen. `@MainActor @Observable`,
/// matching `StravaUploadModel`'s shape. Connecting fetches the two HRR-zone
/// inputs (max HR, resting HR) and writes them into `RideSettings`, which is what
/// makes WHOOP the source of truth for the ride's HR zones.
@MainActor
@Observable
final class WhoopModel {
    private(set) var state: WhoopConnectionState

    /// Today's WHOOP recovery (score / HRV / resting HR), refreshed alongside the
    /// zones. Nil until fetched, or when WHOOP has no scored recovery yet.
    private(set) var recovery: WhoopRecovery?

    private let service: WhoopService?
    private let authenticator = OAuthAuthenticator()
    private let config: WhoopOAuthConfig?

    init() {
        self.config = WhoopSecrets.config
        if let config {
            self.service = WhoopService(config: config, tokens: KeychainTokenStore.whoop())
            // We can't touch the actor's `isConnected` synchronously here; start
            // `.disconnected` and let `.task { await syncOnAppear(settings:) }`
            // upgrade it to `.connected` if tokens already exist.
            self.state = .disconnected
        } else {
            self.service = nil
            self.state = .unavailable
        }
    }

    var isConfigured: Bool { config != nil }

    /// Advisory readiness derived from today's recovery (never changes settings —
    /// just suggests). Nil when there's no scored recovery to advise on.
    var readiness: WhoopReadiness? {
        recovery.flatMap(WhoopReadiness.init(from:))
    }

    /// Reconcile the visible state with what's actually in the Keychain, and if we
    /// come up already connected, pull today's zones + recovery. Call from the
    /// setup view's `.task`; safe to call repeatedly.
    ///
    /// This is the pre-ride refresh. SetupView is the screen you pass through on
    /// the way to every ride (the app enters the ride once the trainer and strap
    /// are ready, and drops back here afterwards), so refreshing on each appear is
    /// what keeps the resting HR the zones are built from current — WHOOP rescores
    /// it each morning once your sleep is scored, and a ride is now permanently
    /// stamped with the zoning it was ridden against. One small request per visit
    /// is cheap next to riding a day-old resting HR.
    ///
    /// Quietly: unlike the Refresh button, a failure here (offline, WHOOP down)
    /// must NOT pop an error or knock the user off WHOOP zones — we stay
    /// `.connected` and keep riding the last-fetched values, which remain the zone
    /// model precisely because they're still stored.
    ///
    /// The `clearWhoopZones()` in `disconnect` is the only thing that drops them.
    func syncOnAppear(settings: RideSettings) async {
        guard let service else { return }
        // Don't stomp a transient state (authorizing/refreshing/failed) mid-flow.
        switch state {
        case .disconnected, .connected:
            if await service.isConnected {
                state = .refreshing
                do {
                    try await fetchZonesAndRecovery(into: settings, service: service)
                } catch {
                    // Swallow — no error banner on appear; the cached zones stand.
                }
                state = .connected
            } else {
                state = .disconnected
            }
        default:
            break
        }
    }

    /// Authorize (if needed) and pull the latest zone inputs into `settings`,
    /// switching the app onto WHOOP zones on success.
    func connectAndRefresh(settings: RideSettings) async {
        guard let service, let config else { state = .unavailable; return }
        do {
            if await service.isConnected == false {
                state = .authorizing
                // WHOOP requires a per-attempt CSRF `state`, bound into both the
                // authorize URL and the callback verification.
                let csrfState = WhoopOAuth.makeState()
                let code = try await authenticator.authorize(
                    authorizeURL: WhoopOAuth.authorizeURL(config: config, state: csrfState),
                    callbackScheme: config.redirectScheme,
                    parseCallback: { url in
                        guard let url else { return .failure(WhoopAuthError.malformedCallback) }
                        return WhoopOAuth.parseCallback(url, expectedState: csrfState).mapError { $0 as Error }
                    },
                    cancelledError: WhoopAuthError.userCancelled)
                try await service.exchange(code: code)
            }
            state = .refreshing
            try await fetchZonesAndRecovery(into: settings, service: service)
            state = .connected
        } catch WhoopAuthError.userCancelled {
            // User backed out of the consent sheet; return to whatever we were.
            state = await service.isConnected ? .connected : .disconnected
        } catch {
            state = .failed(message: friendly(error))
        }
    }

    /// Re-fetch zone inputs for an already-connected account (no web sheet).
    func refresh(settings: RideSettings) async {
        guard let service else { state = .unavailable; return }
        guard await service.isConnected else { state = .disconnected; return }
        do {
            state = .refreshing
            try await fetchZonesAndRecovery(into: settings, service: service)
            state = .connected
        } catch {
            state = .failed(message: friendly(error))
        }
    }

    /// Pull max HR, body weight, and today's recovery in one shot, apply the
    /// zones, store the weight (when WHOOP has one on file), and store the
    /// recovery for the readiness display. Shared by connect, refresh, and the
    /// pre-ride sync so all three keep zones and readiness in lockstep from a
    /// single recovery fetch — and all three land on WHOOP's zones, since a stored
    /// max/resting HR *is* the zone model (`RideSettings.zoning`).
    private func fetchZonesAndRecovery(into settings: RideSettings,
                                       service: WhoopService) async throws {
        let result = try await service.fetchZonesAndRecovery()
        guard let restingHR = result.recovery?.restingHR else {
            throw WhoopServiceError.noRestingHR
        }
        settings.storeWhoopInputs(maxHR: result.maxHR, restingHR: restingHR)
        if let weightKg = result.weightKg {
            settings.storeWhoopWeight(weightKg)
        }
        recovery = result.recovery
    }

    /// Forget the WHOOP account and stop using its data (revert to manual LTHR
    /// zones and manually entered weight).
    func disconnect(settings: RideSettings) async {
        await service?.disconnect()
        settings.clearWhoopZones()
        recovery = nil
        state = isConfigured ? .disconnected : .unavailable
    }

    private func friendly(_ error: Error) -> String {
        switch error {
        case WhoopServiceError.notAuthorized: return "Not connected to WHOOP."
        case WhoopServiceError.refreshTokenExpired:
            return "Your WHOOP sign-in has expired. Tap Connect WHOOP to sign in again."
        case WhoopServiceError.noRestingHR: return "WHOOP has no recent resting-HR reading yet."
        case WhoopServiceError.http(let status, let body):
            // Include WHOOP's own message when there is one: a bare status code
            // can't distinguish an expired grant from a bad request, which is
            // exactly what made a 400 here hard to diagnose. Reduced to the most
            // specific field and trimmed so a stray HTML error page can't blow out
            // the banner.
            let detail = WhoopService.errorSummary(from: body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(200)
            return detail.isEmpty
                ? "WHOOP returned an error (HTTP \(status))."
                : "WHOOP returned an error (HTTP \(status)): \(detail)"
        case WhoopServiceError.decoding: return "Couldn't read WHOOP's response."
        case WhoopAuthError.accessDenied: return "WHOOP access was declined."
        case WhoopAuthError.stateMismatch: return "WHOOP sign-in couldn't be verified — try again."
        default: return "Couldn't reach WHOOP. Check your connection and try again."
        }
    }
}
