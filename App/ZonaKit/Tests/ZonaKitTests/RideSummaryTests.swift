import Foundation
import Testing
@testable import ZonaKit

@Suite("Ride summary")
struct RideSummaryTests {
    /// Build a recording of `count` samples each at `watts`.
    private func steady(_ watts: Int, count: Int, ftp: Int = 200,
                        zone: PowerZone = .z2Endurance) -> RideRecording {
        let samples = (0..<count).map { RideSample(secondsFromStart: $0, powerW: watts) }
        return RideRecording(ftp: ftp, zone: zone, startedAt: Date(), samples: samples)
    }

    @Test func averageAndMaxAndDuration() {
        let samples = [100, 200, 300].enumerated().map {
            RideSample(secondsFromStart: $0.offset, powerW: $0.element)
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        let s = rec.summary()
        #expect(s.durationSeconds == 3)
        #expect(s.averagePowerW == 200)
        #expect(s.maxPowerW == 300)
    }

    @Test func normalizedEqualsAverageForSteadyPower() {
        // Constant power → NP == average power, even across the 30s window.
        let rec = steady(130, count: 120)
        let s = rec.summary()
        #expect(s.averagePowerW == 130)
        #expect(s.normalizedPowerW == 130)
    }

    @Test func normalizedFallsBackToMeanUnder30Samples() {
        #expect(RideRecording.normalizedPower([100, 200]) == 150)
    }

    /// The 30-sample window boundary: 29 samples take the mean fallback, 30 take
    /// the real rolling-window path. Both are 150 W steady here, so they agree —
    /// which is the point. An off-by-one in the `powers.count >= window` guard
    /// (or in `reserveCapacity`/the loop bounds) would crash or skew at exactly
    /// this size rather than at any value the other NP tests use.
    @Test func normalizedPowerAtTheThirtySampleWindowBoundary() {
        #expect(RideRecording.normalizedPower(Array(repeating: 150, count: 29)) == 150)
        #expect(RideRecording.normalizedPower(Array(repeating: 150, count: 30)) == 150)
        #expect(RideRecording.normalizedPower(Array(repeating: 150, count: 31)) == 150)
    }

    /// NP's whole reason for existing: a variable ride is metabolically harder
    /// than its average watts suggest, so NP must come out ABOVE the mean. Two
    /// minutes split 60 s at 100 W / 60 s at 300 W averages 200 W but normalizes
    /// to 244 W — the 4th-power weighting of the hard block. Every other NP test
    /// here uses steady power, where NP == average and a broken implementation
    /// (e.g. 4th-powering raw samples instead of the rolling means) would still
    /// pass. This is the one that actually exercises the weighting.
    @Test func normalizedPowerExceedsAverageForVariablePower() {
        let spiky = Array(repeating: 100, count: 60) + Array(repeating: 300, count: 60)
        #expect(spiky.reduce(0, +) / spiky.count == 200)      // plain average
        #expect(RideRecording.normalizedPower(spiky) == 244)   // NP weights the hard block
    }

    /// The complement: power that alternates every SECOND rather than in blocks
    /// averages out *inside* each 30 s window, so NP lands back at the mean. This
    /// pins that the smoothing is genuinely a 30 s rolling average — an
    /// implementation that 4th-powered each raw sample would report ~244 here too
    /// (same values, same mean), so this test is what distinguishes the two.
    @Test func normalizedPowerSmoothsSecondBySecondVariation() {
        let alternating = (0..<120).map { $0.isMultiple(of: 2) ? 100 : 300 }
        #expect(alternating.reduce(0, +) / alternating.count == 200)
        #expect(RideRecording.normalizedPower(alternating) == 200)
    }

    @Test func normalizedPowerIsZeroForNoSamples() {
        #expect(RideRecording.normalizedPower([]) == 0)
    }

    /// Leg power summarizes on its own axis, and — the point of keeping it a
    /// separate channel — leaves every trainer-derived stat exactly as it would
    /// be without a meter: avg, max, NP and time-in-zone all still read the
    /// trainer, even though the meter reports higher watts throughout.
    @Test func powerMeterSummarizesWithoutSkewingTrainerStats() {
        // FTP 200 → Z2 band 110…150. Trainer holds 130 (in-band); the Quarq reads
        // a few watts higher, as it does in reality (drivetrain loss).
        let samples = (0..<3).map {
            RideSample(secondsFromStart: $0, powerW: 130, powerMeterW: 136 + $0)
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        let s = rec.summary()

        #expect(s.averagePowerMeterW == 137)   // (136+137+138)/3
        #expect(s.maxPowerMeterW == 138)
        #expect(s.normalizedPowerMeterW == RideRecording.normalizedPower([136, 137, 138]))
        // Trainer stats unmoved by the higher meter readings.
        #expect(s.averagePowerW == 130)
        #expect(s.maxPowerW == 130)
        #expect(s.timeInZoneSeconds == 3)      // scored on trainer watts, all in-band
    }

    /// No meter paired → nil, not 0. A fabricated 0 would read as "you produced
    /// no leg power"; nil lets the summary show "—".
    @Test func powerMeterStatsAreNilWithoutAMeter() {
        let s = steady(130, count: 10).summary()
        #expect(s.averagePowerMeterW == nil)
        #expect(s.maxPowerMeterW == nil)
        #expect(s.normalizedPowerMeterW == nil)
    }

    /// Meter NP is computed over the meter's own watts, independent of the
    /// trainer's — a steady meter reading normalizes to itself over the 30s
    /// window, same as the trainer's NP does.
    @Test func normalizedPowerMeterEqualsAverageForSteadyPower() {
        let samples = (0..<40).map {
            RideSample(secondsFromStart: $0, powerW: 130, powerMeterW: 136)
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        let s = rec.summary()
        #expect(s.averagePowerMeterW == 136)
        #expect(s.normalizedPowerMeterW == 136)
    }

    /// A meter that drops mid-ride averages over the seconds it actually
    /// reported, rather than counting the silent seconds as zero watts.
    @Test func powerMeterAveragesOnlyReportedSeconds() {
        let samples = [
            RideSample(secondsFromStart: 0, powerW: 130, powerMeterW: 140),
            RideSample(secondsFromStart: 1, powerW: 130),                    // meter dropped
            RideSample(secondsFromStart: 2, powerW: 130, powerMeterW: 150),
        ]
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        let s = rec.summary()
        #expect(s.averagePowerMeterW == 145)   // (140+150)/2, not /3
        #expect(s.maxPowerMeterW == 150)
    }

    @Test func timeInZoneCountsInBandSeconds() {
        // FTP 200 → Z2 band 110…150. 130 is in-band, 90 (Z1) and 200 (Z4) are not.
        let powers = [90, 130, 130, 130, 200]
        let samples = powers.enumerated().map {
            RideSample(secondsFromStart: $0.offset, powerW: $0.element)
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        #expect(rec.timeInZone() == 3)
        #expect(rec.summary().timeInZoneSeconds == 3)
        #expect(abs(rec.timeInZoneFraction - 0.6) < 0.0001)
    }

    /// `timeInZone` defaults to the recording's own target zone, but takes an
    /// explicit one — the argument form is what a "how long was I in Z1?" readout
    /// on a Z2 ride would call. Same samples, scored against a different band.
    @Test func timeInZoneScoresAnExplicitZoneNotJustTheTarget() {
        // FTP 200 → Z1 0…110, Z2 110…150, Z4 180…210.
        let powers = [90, 130, 130, 130, 200]
        let samples = powers.enumerated().map {
            RideSample(secondsFromStart: $0.offset, powerW: $0.element)
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        #expect(rec.timeInZone(.z2Endurance) == 3)   // the ride's own target
        #expect(rec.timeInZone(.z1Recovery) == 1)    // the 90 W sample
        #expect(rec.timeInZone(.z4Threshold) == 1)   // the 200 W sample
        #expect(rec.timeInZone(.z6Anaerobic) == 0)   // never ridden
    }

    /// `summary()` prefers the recorded wall-clock duration, but a recording built
    /// without one (0 is the sentinel — every hand-built recording in these tests,
    /// and the `RideRecording` init's default) falls back to counting samples.
    /// `finishStampsWallClockDuration` covers the branch where a real duration
    /// wins; this pins the other side of that ternary, the same way
    /// `totalTimeSecondsFallsBackWhenDurationIsZero` does for the TCX export.
    @Test func summaryDurationFallsBackToSampleCountWhenUnrecorded() {
        let rec = steady(130, count: 7)
        #expect(rec.durationSeconds == 0)             // no wall-clock duration stamped
        #expect(rec.summary().durationSeconds == 7)   // …so sample count stands in

        // And when one IS stamped, it wins over the sample count.
        let timed = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(),
                                  samples: rec.samples, durationSeconds: 90)
        #expect(timed.summary().durationSeconds == 90)
    }

    /// The fallback has to hold for the derived fraction too: `timeInZoneFraction`
    /// divides by the same duration, so an unstamped recording must divide by the
    /// sample count rather than by 0 (which would be a NaN on the summary screen).
    @Test func timeInZoneFractionUsesTheSameDurationFallback() {
        let powers = [90, 130, 130, 130, 200]        // 3 of 5 in Z2
        let samples = powers.enumerated().map {
            RideSample(secondsFromStart: $0.offset, powerW: $0.element)
        }
        let unstamped = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        #expect(abs(unstamped.timeInZoneFraction - 0.6) < 0.0001)   // 3/5, not 3/0

        // A stamped duration lengthens the denominator: seconds where no sample
        // landed at all still count as time not in zone.
        let stamped = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(),
                                    samples: samples, durationSeconds: 10)
        #expect(abs(stamped.timeInZoneFraction - 0.3) < 0.0001)     // 3/10
    }

    /// A recording with no samples at all (the trainer never reported) must
    /// summarize to zeros rather than crash on an empty reduce or divide by zero.
    @Test func emptyRecordingSummarizesToZeros() {
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: [])
        let s = rec.summary()
        #expect(s.durationSeconds == 0)
        #expect(s.averagePowerW == 0)
        #expect(s.maxPowerW == 0)
        #expect(s.normalizedPowerW == 0)
        #expect(s.timeInZoneSeconds == 0)
        #expect(s.distanceMeters == 0)
        #expect(rec.timeInZoneFraction == 0)   // guarded, not NaN
    }

    // MARK: Distance (speed integration)

    private func ride(speeds kph: [Double?], seconds: [Int]? = nil) -> RideRecording {
        let secs = seconds ?? Array(0..<kph.count)
        let samples = zip(secs, kph).map { RideSample(secondsFromStart: $0, speedKph: $1) }
        return RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
    }

    @Test func distanceIntegratesSteadySpeed() {
        // 36 km/h = 10 m/s. Three samples at 0,1,2s → two 1-second gaps →
        // 10 m + 10 m = 20 m. The last sample has no next interval.
        let rec = ride(speeds: [36, 36, 36])
        #expect(abs(rec.distanceMeters - 20) < 1e-6)
        #expect(abs(rec.summary().distanceMeters - 20) < 1e-6)
    }

    @Test func distanceUsesActualGapAcrossDropouts() {
        // A dropped second: samples at 0 and 2 (gap = 2s) at 18 km/h = 5 m/s →
        // 5 × 2 = 10 m. Proves we integrate the real gap, not a fixed 1 Hz.
        let rec = ride(speeds: [18, 18], seconds: [0, 2])
        #expect(abs(rec.distanceMeters - 10) < 1e-6)
    }

    @Test func distanceSkipsIntervalsWithNoSpeed() {
        // Middle sample reports no speed → its interval contributes 0.
        // gaps: [0→1] 10 m/s ×1 = 10, [1→2] nil = 0. Total 10 m.
        let rec = ride(speeds: [36, nil, 36])
        #expect(abs(rec.distanceMeters - 10) < 1e-6)
    }

    @Test func distanceZeroWhenNoSpeedSamples() {
        // Power/HR-only ride (no trainer speed) → 0, same as before.
        let samples = (0..<10).map { RideSample(secondsFromStart: $0, powerW: 150) }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        #expect(rec.distanceMeters == 0)
        #expect(rec.summary().distanceMeters == 0)
    }

    @Test func cumulativeDistanceIsMonotonicRunningTotal() {
        // 10 m/s across 0,1,2,3s → running totals 10,20,30,30 (last has no next).
        let rec = ride(speeds: [36, 36, 36, 36])
        let cum = rec.cumulativeDistanceMeters()
        #expect(cum.count == 4)
        #expect(abs(cum[0] - 10) < 1e-6)
        #expect(abs(cum[1] - 20) < 1e-6)
        #expect(abs(cum[2] - 30) < 1e-6)
        #expect(abs(cum[3] - 30) < 1e-6)
        #expect(abs((cum.last ?? 0) - rec.distanceMeters) < 1e-6)
    }

    /// The running total integrates the *actual* gap between samples, not a
    /// fixed 1 Hz — the same rule `distanceUsesActualGapAcrossDropouts` pins for
    /// the scalar total, but per-trackpoint. This matters because
    /// `cumulativeDistanceMeters` is what stamps `<DistanceMeters>` on each TCX
    /// trackpoint: assuming 1 s per interval would under-report distance across
    /// every dropped notification, and Strava would show a short ride.
    @Test func cumulativeDistanceUsesActualGapAcrossDropouts() {
        // 18 km/h = 5 m/s. Samples at 0, 2 (a dropped second), 3.
        // [0→2] 5 × 2 = 10 m; [2→3] 5 × 1 = 5 m; last sample has no next.
        let rec = ride(speeds: [18, 18, 18], seconds: [0, 2, 3])
        let cum = rec.cumulativeDistanceMeters()
        #expect(cum.count == 3)
        #expect(abs(cum[0] - 10) < 1e-6)   // the 2 s gap, not 5 m
        #expect(abs(cum[1] - 15) < 1e-6)
        #expect(abs(cum[2] - 15) < 1e-6)   // final sample contributes nothing
        // Stays consistent with the scalar total, as the steady case does.
        #expect(abs((cum.last ?? 0) - rec.distanceMeters) < 1e-6)
    }

    /// A sample with no speed contributes nothing for its interval, so the
    /// running total plateaus there rather than back-filling — and the entries
    /// stay aligned one-to-one with `samples`, which the TCX exporter relies on
    /// to pair each distance with its trackpoint.
    @Test func cumulativeDistancePlateausAcrossSamplesWithNoSpeed() {
        // 10 m/s at 0; no speed at 1; 10 m/s at 3 (last, contributes nothing).
        // [0→1] 10 × 1 = 10 m; [1→3] no speed = 0 m.
        let rec = ride(speeds: [36, nil, 36], seconds: [0, 1, 3])
        let cum = rec.cumulativeDistanceMeters()
        #expect(cum.count == rec.samples.count)   // one entry per sample
        #expect(abs(cum[0] - 10) < 1e-6)
        #expect(abs(cum[1] - 10) < 1e-6)          // plateau, not interpolated
        #expect(abs(cum[2] - 10) < 1e-6)
        // Never decreases, whatever the speed gaps look like.
        #expect(zip(cum, cum.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// Samples arriving out of order are sorted before integrating, so the
    /// running total is monotonic regardless of input order — `distanceMeters`
    /// and the TCX exporter both depend on this (`sortsUnorderedSamples` pins
    /// the exporter's side).
    @Test func cumulativeDistanceSortsUnorderedSamples() {
        let rec = ride(speeds: [36, 36, 36], seconds: [2, 0, 1])
        let cum = rec.cumulativeDistanceMeters()
        #expect(abs(cum[0] - 10) < 1e-6)
        #expect(abs(cum[1] - 20) < 1e-6)
        #expect(abs(cum[2] - 20) < 1e-6)
    }

    /// A recording with no samples yields no entries rather than crashing on the
    /// empty loop or returning a spurious [0].
    @Test func cumulativeDistanceIsEmptyForNoSamples() {
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: [])
        #expect(rec.cumulativeDistanceMeters().isEmpty)
    }
}
