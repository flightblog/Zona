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

    private let service: WhoopService?
    private let authenticator = WhoopAuthenticator()
    private let config: WhoopOAuthConfig?

    init() {
        self.config = WhoopSecrets.config
        if let config {
            self.service = WhoopService(config: config, tokens: KeychainWhoopTokenStore())
            // We can't touch the actor's `isConnected` synchronously here; start
            // `.disconnected` and let `.task { await syncConnectionState() }`
            // upgrade it to `.connected` if tokens already exist.
            self.state = .disconnected
        } else {
            self.service = nil
            self.state = .unavailable
        }
    }

    var isConfigured: Bool { config != nil }

    /// Reconcile the visible state with what's actually in the Keychain. Call from
    /// the view's `.task`; safe to call repeatedly.
    func syncConnectionState() async {
        guard let service else { return }
        // Don't stomp a transient state (authorizing/refreshing/failed) mid-flow.
        switch state {
        case .disconnected, .connected:
            state = await service.isConnected ? .connected : .disconnected
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
                let code = try await authenticator.authorize(config: config)
                try await service.exchange(code: code)
            }
            state = .refreshing
            let inputs = try await service.fetchZoneInputs()
            settings.applyWhoopZones(maxHR: inputs.maxHR, restingHR: inputs.restingHR)
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
            let inputs = try await service.fetchZoneInputs()
            settings.applyWhoopZones(maxHR: inputs.maxHR, restingHR: inputs.restingHR)
            state = .connected
        } catch {
            state = .failed(message: friendly(error))
        }
    }

    /// Forget the WHOOP account and stop using its zones (revert to manual LTHR).
    func disconnect(settings: RideSettings) async {
        await service?.disconnect()
        settings.clearWhoopZones()
        state = isConfigured ? .disconnected : .unavailable
    }

    private func friendly(_ error: Error) -> String {
        switch error {
        case WhoopServiceError.notAuthorized: return "Not connected to WHOOP."
        case WhoopServiceError.noRestingHR: return "WHOOP has no recent resting-HR reading yet."
        case WhoopServiceError.http(let status, _): return "WHOOP returned an error (HTTP \(status))."
        case WhoopServiceError.decoding: return "Couldn't read WHOOP's response."
        case WhoopAuthError.accessDenied: return "WHOOP access was declined."
        case WhoopAuthError.stateMismatch: return "WHOOP sign-in couldn't be verified — try again."
        default: return "Couldn't reach WHOOP. Check your connection and try again."
        }
    }
}
