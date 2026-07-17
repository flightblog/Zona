import Foundation
import SwiftData
import SwiftUI
import ZonaKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where a ride sits in the Strava-upload flow, driving the summary button.
enum StravaUploadState: Equatable {
    case unavailable                       // no client secret configured on this build
    case idle                              // ready to upload, not yet uploaded
    case authorizing
    case uploading
    case uploaded(activityId: Int64)       // success → "View on Strava"
    case duplicate(activityId: Int64?)     // already on Strava
    case failed(message: String)
}

/// Drives one ride's Strava upload from the summary screen. `@MainActor
/// @Observable`, matching `TrainerController`'s shape. Connects on first upload
/// (no separate account screen needed) and writes the resulting activity id back
/// onto the `Ride` so it's never uploaded twice.
@MainActor
@Observable
final class StravaUploadModel {
    private(set) var state: StravaUploadState

    private let service: StravaService?
    private let authenticator = OAuthAuthenticator()
    private let config: StravaOAuthConfig?

    init(ride: Ride) {
        self.config = StravaSecrets.config
        if let config {
            self.service = StravaService(config: config, tokens: KeychainTokenStore.strava())
        } else {
            self.service = nil
        }

        // Already uploaded? Start in the terminal state (no network on open).
        if let id = ride.stravaActivityId {
            state = .uploaded(activityId: id)
        } else if config == nil {
            state = .unavailable
        } else {
            state = .idle
        }
    }

    /// Authorize if needed, upload the ride's TCX, and on success/duplicate
    /// persist the activity id back onto the ride via `context`.
    func upload(ride: Ride, context: ModelContext) async {
        guard let service, let config else { state = .unavailable; return }

        do {
            // Connect on first use.
            if await service.isConnected == false {
                state = .authorizing
                let code = try await authenticator.authorize(
                    authorizeURL: StravaOAuth.authorizeURL(config: config),
                    callbackScheme: config.redirectScheme,
                    parseCallback: { url in
                        guard let url else { return .failure(StravaAuthError.malformedCallback) }
                        return StravaOAuth.parseCallback(url).mapError { $0 as Error }
                    },
                    cancelledError: StravaAuthError.userCancelled)
                _ = try await service.exchange(code: code)
            }

            state = .uploading
            let base = ride.tcxFilename.replacingOccurrences(of: ".tcx", with: "")
            let outcome = try await service.upload(
                tcx: ride.tcxString(), filenameBase: base, activityName: ride.stravaActivityName)

            switch outcome {
            case .succeeded(let id):
                persist(activityId: id, on: ride, context: context)
                state = .uploaded(activityId: id)
            case .duplicate(let id):
                if let id { persist(activityId: id, on: ride, context: context) }
                state = .duplicate(activityId: id)
            case .failed(let message):
                state = .failed(message: message)
            case .pending:
                state = .failed(message: "Strava is still processing — try again shortly.")
            }
        } catch StravaAuthError.userCancelled {
            state = .idle   // user backed out of the consent sheet; no error UI
        } catch {
            state = .failed(message: friendly(error))
        }
    }

    /// Open the uploaded activity on strava.com.
    func openOnStrava() {
        let id: Int64?
        switch state {
        case .uploaded(let activityId): id = activityId
        case .duplicate(let activityId): id = activityId
        default: id = nil
        }
        guard let id else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(stravaActivityURL(id))
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(stravaActivityURL(id))
        #endif
    }

    private func persist(activityId: Int64, on ride: Ride, context: ModelContext) {
        ride.stravaActivityId = activityId
        ride.stravaUploadedAt = Date()
        try? context.save()
    }

    private func friendly(_ error: Error) -> String {
        switch error {
        case StravaServiceError.notAuthorized: return "Not connected to Strava."
        case StravaServiceError.uploadTimedOut: return "Strava took too long to process the ride."
        case StravaServiceError.http(let status, _): return "Strava returned an error (HTTP \(status))."
        case StravaServiceError.decoding: return "Couldn't read Strava's response."
        case StravaAuthError.accessDenied: return "Strava access was declined."
        case StravaAuthError.missingScope: return "Zona needs permission to upload activities."
        default: return "Upload failed. Check your connection and try again."
        }
    }
}
