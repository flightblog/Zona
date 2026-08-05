import Foundation
import ZonaKit

/// Bridges a persisted `Ride` to a shareable TCX file. Strava (and TrainingPeaks,
/// intervals.icu, …) import TCX directly, so this is the onward-sync path without
/// any accounts or OAuth.
extension Ride {
    /// This ride's samples bridged to the exporter's pure value type. Carries
    /// both power channels; `TCXExporter` decides which one the file uses.
    private var tcxSamples: [TCXSample] {
        (samples ?? [])
            .sorted { $0.secondsFromStart < $1.secondsFromStart }
            .map {
                TCXSample(
                    secondsFromStart: $0.secondsFromStart,
                    powerW: $0.powerW,
                    cadenceRpm: $0.cadenceRpm,
                    speedKph: $0.speedKph,
                    heartRateBpm: $0.heartRateBpm,
                    powerMeterW: $0.powerMeterW
                )
            }
    }

    /// Which power channel this ride's TCX exports — leg power when a crank
    /// meter covered enough of the ride, the trainer's estimate otherwise. The
    /// summary reads this to caption the fallback case, so a rider knows when an
    /// upload carries trainer watts rather than crank watts.
    var tcxPowerSource: TCXPowerSource {
        TCXPowerSource.resolve(samples: tcxSamples)
    }

    /// The ride as a TCX (TrainingCenterDatabase v2) XML string.
    func tcxString() -> String {
        TCXExporter.makeTCX(start: date, samples: tcxSamples, durationSeconds: durationSec)
    }

    /// The Strava activity title for this ride, e.g. `Zona Z2 Endurance`.
    var stravaActivityName: String {
        "Zona \(zone.name)"
    }

    /// A filesystem-safe filename for this ride, e.g. `Zona-2026-07-01-0730.tcx`.
    var tcxFilename: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "Zona-\(f.string(from: date)).tcx"
    }

    /// Write the TCX to a temporary file and return its URL for sharing. Strava
    /// keys off the `.tcx` extension, so the filename matters.
    func writeTCXTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(tcxFilename)
        try tcxString().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
