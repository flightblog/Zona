import Foundation
import SwiftData
import ZonaKit

/// Persisted record of one Z2 (or other zone) ride. Summary columns are
/// precomputed at save time from ZonaKit's `RideSummary` so History/list views
/// don't have to walk every sample.
///
/// CloudKit-readiness (so sync can be enabled later with no migration):
/// - every property has a default value,
/// - no `.unique` attribute constraints,
/// - the samples relationship is optional.
@Model
final class Ride {
    var id: UUID = UUID()
    var date: Date = Date()
    var ftp: Int = 0
    /// `PowerZone.rawValue` — enums aren't directly storable, and an Int is
    /// CloudKit-friendly.
    var zoneRaw: Int = PowerZone.z2Endurance.rawValue

    var durationSec: Int = 0
    var avgPowerW: Int = 0
    var normalizedPowerW: Int = 0
    var maxPowerW: Int = 0
    var timeInZoneSec: Int = 0
    /// Simulated distance in metres (trainer speed integrated; not GPS).
    var distanceMeters: Double = 0

    // Heart-rate summary. Zones are HR-based, so these are the headline.
    var lthr: Int = 0
    /// `HRZone.rawValue`.
    var hrZoneRaw: Int = HRZone.z2Endurance.rawValue
    var avgHeartRate: Int = 0
    var maxHeartRate: Int = 0
    var timeInHRZoneSec: Int = 0

    // The WHOOP HRR inputs this ride was scored against, or nil when it was ridden
    // on the manual LTHR bands. Persisted per-ride (rather than read from current
    // settings) because the zone model is a fact *about the ride*: without them,
    // connecting WHOOP would retroactively rescore old LTHR rides, and
    // disconnecting it would silently restate WHOOP rides against LTHR. Optional
    // with no default keeps them CloudKit-safe and lightweight-migrates existing
    // rides to nil = LTHR (same pattern as `hrvRMSSDms`).
    var whoopMaxHR: Int?
    var whoopRestingHR: Int?
    /// Heart-rate variability (RMSSD, ms) for the ride, or nil when the strap
    /// reported too few R-R beats (or none — e.g. a sensor that omits R-R). nil,
    /// not 0, so the summary can show "—" instead of a fabricated value.
    /// Optional keeps it CloudKit-safe (no default needed, migrates old rides).
    var hrvRMSSDms: Int?

    /// Strava activity id once this ride has been uploaded, else nil. Optional
    /// (no default) keeps it CloudKit-safe and lightweight-migrates old rides
    /// (same pattern as `hrvRMSSDms`). Powers the "View on Strava" link and the
    /// re-upload guard — a ride with a non-nil id is never uploaded again.
    var stravaActivityId: Int64?
    /// When the upload to Strava succeeded (nil = never uploaded).
    var stravaUploadedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \RideSampleModel.ride)
    var samples: [RideSampleModel]? = []

    init(id: UUID = UUID(),
         date: Date = Date(),
         ftp: Int = 0,
         zoneRaw: Int = PowerZone.z2Endurance.rawValue,
         durationSec: Int = 0,
         avgPowerW: Int = 0,
         normalizedPowerW: Int = 0,
         maxPowerW: Int = 0,
         timeInZoneSec: Int = 0,
         distanceMeters: Double = 0,
         lthr: Int = 0,
         hrZoneRaw: Int = HRZone.z2Endurance.rawValue,
         avgHeartRate: Int = 0,
         maxHeartRate: Int = 0,
         timeInHRZoneSec: Int = 0,
         whoopMaxHR: Int? = nil,
         whoopRestingHR: Int? = nil,
         hrvRMSSDms: Int? = nil,
         stravaActivityId: Int64? = nil,
         stravaUploadedAt: Date? = nil) {
        self.id = id
        self.date = date
        self.ftp = ftp
        self.zoneRaw = zoneRaw
        self.durationSec = durationSec
        self.avgPowerW = avgPowerW
        self.normalizedPowerW = normalizedPowerW
        self.maxPowerW = maxPowerW
        self.timeInZoneSec = timeInZoneSec
        self.distanceMeters = distanceMeters
        self.lthr = lthr
        self.hrZoneRaw = hrZoneRaw
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.timeInHRZoneSec = timeInHRZoneSec
        self.whoopMaxHR = whoopMaxHR
        self.whoopRestingHR = whoopRestingHR
        self.hrvRMSSDms = hrvRMSSDms
        self.stravaActivityId = stravaActivityId
        self.stravaUploadedAt = stravaUploadedAt
    }

    var zone: PowerZone { PowerZone(rawValue: zoneRaw) ?? .z2Endurance }
    var hrZone: HRZone { HRZone(rawValue: hrZoneRaw) ?? .z2Endurance }

    /// The HR-zone model this ride was ridden against: WHOOP's HRR bands when the
    /// ride carries both WHOOP inputs, else the manual LTHR bands. Every HR-zone
    /// readout for this ride (target band, time-in-zone, per-zone breakdown, the
    /// summary chart's shaded band) resolves through here, so a ride always reads
    /// back against the model the rider was actually aiming at.
    var zoning: RideHRZoning {
        RideHRZoning.resolve(maxHR: whoopMaxHR, restingHR: whoopRestingHR, lthr: lthr)
    }

    var timeInZoneFraction: Double {
        durationSec > 0 ? Double(timeInZoneSec) / Double(durationSec) : 0
    }

    var timeInHRZoneFraction: Double {
        durationSec > 0 ? Double(timeInHRZoneSec) / Double(durationSec) : 0
    }
}

/// One second of a persisted ride. Metrics optional (CloudKit-friendly and true
/// to the source — a trainer may not report every field every second).
@Model
final class RideSampleModel {
    var secondsFromStart: Int = 0
    var powerW: Int?
    var cadenceRpm: Int?
    var speedKph: Double?
    var heartRateBpm: Int?
    /// Raw R-R (beat-to-beat) intervals in seconds captured during this second,
    /// kept so HRV can be recomputed later (a different filter, SDNN, an HRV
    /// chart) without re-riding. nil when the strap reported no R-R this second.
    /// SwiftData stores the scalar array as an archived attribute; optional keeps
    /// it CloudKit-safe and lightweight-migrates existing rides.
    var rrIntervalsSec: [Double]?

    var ride: Ride?

    init(secondsFromStart: Int = 0,
         powerW: Int? = nil,
         cadenceRpm: Int? = nil,
         speedKph: Double? = nil,
         heartRateBpm: Int? = nil,
         rrIntervalsSec: [Double]? = nil) {
        self.secondsFromStart = secondsFromStart
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
        self.rrIntervalsSec = rrIntervalsSec
    }
}

extension Ride {
    /// Maps this saved ride into ZonaKit's pure history-aggregation input, so
    /// the all-time stats view can reduce over `RideHistoryEntry` without
    /// ZonaKit needing to know about SwiftData. The per-zone HR breakdown is
    /// recomputed here from the stored per-second samples (only the target-zone
    /// total is persisted), which is why this needs the sample models.
    var historyEntry: RideHistoryEntry {
        let bpms = (samples ?? []).compactMap(\.heartRateBpm)
        let secondsPerHRZone = zoning.secondsPerZone(bpms: bpms)
        return RideHistoryEntry(date: date, durationSec: durationSec, distanceMeters: distanceMeters,
                                avgPowerW: avgPowerW, timeInHRZoneSec: timeInHRZoneSec,
                                secondsPerHRZone: secondsPerHRZone)
    }

    /// Map a finished ZonaKit recording into a persistable `Ride`, precomputing
    /// both power- and HR-zone summary columns and attaching the per-second
    /// sample models. The HR summary needs the rider's zone model (`zoning`) and
    /// target `hrZone`, which live in settings rather than the recording; the
    /// WHOOP inputs are stored on the ride so it stays scored against the bands it
    /// was ridden against even if WHOOP is later refreshed or disconnected.
    static func make(from recording: RideRecording, zoning: RideHRZoning, hrZone: HRZone) -> Ride {
        let summary = recording.summary()
        let ride = Ride(
            date: recording.startedAt,
            ftp: recording.ftp,
            zoneRaw: recording.zone.rawValue,
            durationSec: summary.durationSeconds,
            avgPowerW: summary.averagePowerW,
            normalizedPowerW: summary.normalizedPowerW,
            maxPowerW: summary.maxPowerW,
            timeInZoneSec: summary.timeInZoneSeconds,
            distanceMeters: summary.distanceMeters,
            lthr: zoning.storedLTHR,
            hrZoneRaw: hrZone.rawValue,
            avgHeartRate: recording.averageHeartRate,
            maxHeartRate: recording.maxHeartRate,
            timeInHRZoneSec: recording.timeInHRZone(hrZone, zoning: zoning),
            whoopMaxHR: zoning.storedWhoopMaxHR,
            whoopRestingHR: zoning.storedWhoopRestingHR,
            hrvRMSSDms: summary.hrvRMSSDms
        )
        ride.samples = recording.samples.map {
            RideSampleModel(
                secondsFromStart: $0.secondsFromStart,
                powerW: $0.powerW,
                cadenceRpm: $0.cadenceRpm,
                speedKph: $0.speedKph,
                heartRateBpm: $0.heartRateBpm,
                rrIntervalsSec: $0.rrIntervalsSec
            )
        }
        return ride
    }
}
