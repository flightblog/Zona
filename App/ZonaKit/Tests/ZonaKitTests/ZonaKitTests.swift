import Foundation
import Testing
@testable import ZonaKit

@Suite("Zone math")
struct ZoneMathTests {
    let engine = ZoneEngine(ftp: 200)

    @Test func z1Range() {
        #expect(engine.wattRange(for: .z1Recovery) == 0...110)
    }

    @Test func z2Range() {
        #expect(engine.wattRange(for: .z2Endurance) == 110...150)
    }

    @Test func z2SteadyTargetIsMidBand() {
        #expect(engine.steadyTarget(for: .z2Endurance) == 130)
    }

    @Test func classifyPowerIntoZone() {
        #expect(engine.zone(forPower: 90) == .z1Recovery)
        #expect(engine.zone(forPower: 130) == .z2Endurance)
        #expect(engine.zone(forPower: 210) == .z4Threshold)
    }

    @Test func steadyTargetPositionable() {
        // Lower edge of Z2 band.
        #expect(engine.steadyTarget(for: .z2Endurance, position: 0.0) == 110)
        #expect(engine.steadyTarget(for: .z2Endurance, position: 1.0) == 150)
    }
}

@Suite("FTMS encoding")
struct FTMSEncodingTests {
    @Test func setTargetPowerBytes() {
        let cmd = FTMS.setTargetPowerCommand(watts: 130) // 0x0082
        #expect(Array(cmd) == [0x05, 0x82, 0x00])
    }

    @Test func setTargetPowerLittleEndian() {
        let cmd = FTMS.setTargetPowerCommand(watts: 300) // 0x012C
        #expect(Array(cmd) == [0x05, 0x2C, 0x01])
    }

    @Test func stopBytes() {
        #expect(Array(FTMS.stopCommand()) == [0x08, 0x01])
    }

    @Test func parseSuccessResponse() {
        let r = FTMS.parseControlResponse(Data([0x80, 0x00, 0x01]))
        #expect(r?.requested == 0x00)
        #expect(r?.result == .success)
    }

    @Test func parseControlNotPermitted() {
        let r = FTMS.parseControlResponse(Data([0x80, 0x05, 0x05]))
        #expect(r?.result == .controlNotPermitted)
    }

    @Test func rejectsMalformedResponse() {
        #expect(FTMS.parseControlResponse(Data([0x01, 0x02])) == nil)
    }
}

@Suite("Indoor Bike Data decode")
struct IndoorBikeDataTests {
    @Test func decodesSpeedCadencePower() {
        // flags 0x0044 => cadence (bit2) + power (bit6); speed present (bit0 clear).
        var pkt = Data([0x44, 0x00])
        pkt.append(contentsOf: [0xE8, 0x03]) // speed 1000 => 10.00 km/h
        pkt.append(contentsOf: [0xB4, 0x00]) // cadence 180 => 90 rpm
        pkt.append(contentsOf: [0x82, 0x00]) // power 130 W
        let d = IndoorBikeData(pkt)
        #expect(d?.instantaneousSpeedKph == 10.0)
        #expect(d?.instantaneousCadenceRpm == 90.0)
        #expect(d?.instantaneousPowerW == 130)
    }

    @Test func powerOnlyPacket() {
        // flags 0x0041 => moreData bit set (no speed) + power.
        var pkt = Data([0x41, 0x00])
        pkt.append(contentsOf: [0x64, 0x00]) // power 100 W
        let d = IndoorBikeData(pkt)
        #expect(d?.instantaneousSpeedKph == nil)
        #expect(d?.instantaneousPowerW == 100)
    }

    @Test func rejectsTooShort() {
        #expect(IndoorBikeData(Data([0x00])) == nil)
    }
}

@Suite("Ride metrics")
struct RideMetricsTests {
    @Test func powerDelta() {
        var m = RideMetrics(powerW: 118, targetW: 130)
        #expect(m.powerDelta == -12)
        m.powerW = 140
        #expect(m.powerDelta == 10)
    }

    @Test func powerDeltaNilWithoutTarget() {
        #expect(RideMetrics(powerW: 118).powerDelta == nil)
    }
}

@Suite("Ride recorder")
@MainActor
struct RideRecorderTests {
    /// Several ingests within the same second collapse to one sample; last
    /// value per field wins.
    @Test func collapsesToOneHz() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        // Three snapshots inside second 0, two inside second 1.
        rec.ingest(RideMetrics(powerW: 100), at: t0 + .milliseconds(100))
        rec.ingest(RideMetrics(powerW: 120), at: t0 + .milliseconds(400))
        rec.ingest(RideMetrics(powerW: 130, cadenceRpm: 85), at: t0 + .milliseconds(900))
        rec.ingest(RideMetrics(powerW: 140), at: t0 + .milliseconds(1200))
        rec.ingest(RideMetrics(powerW: 150), at: t0 + .milliseconds(1800))

        let recording = rec.finish()
        #expect(recording.samples.count == 2)
        #expect(recording.samples[0].secondsFromStart == 0)
        #expect(recording.samples[0].powerW == 130)   // last write in second 0
        #expect(recording.samples[0].cadenceRpm == 85)
        #expect(recording.samples[1].powerW == 150)    // last write in second 1
    }

    @Test func elapsedTracksSeconds() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 100), at: t0 + .seconds(4) + .milliseconds(500))
        #expect(rec.elapsedSeconds == 5)  // seconds 0…4 → 5 elapsed
    }

    /// Duration is wall-clock elapsed, not sample count: a steady ride where
    /// only two seconds happened to capture a fresh sample but 60 s of real time
    /// passed must report 60 s, so the summary matches the live timer.
    @Test func finishStampsWallClockDuration() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 100), at: t0 + .milliseconds(500))
        rec.ingest(RideMetrics(powerW: 100), at: t0 + .seconds(5))
        let recording = rec.finish(at: t0 + .seconds(60))
        #expect(recording.samples.count == 2)          // only two distinct seconds sampled
        #expect(recording.durationSeconds == 60)       // but a full minute elapsed
        #expect(recording.summary().durationSeconds == 60)
    }

    /// Live accumulated distance integrates speed the same stepwise way the
    /// saved recording does, so the ride screen's running total matches the
    /// summary once the ride ends.
    @Test func liveDistanceMatchesRecording() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        // 36 km/h = 10 m/s held for one second, then a second sample so the
        // first interval integrates (the final sample has no "next", per the
        // integration rule).
        rec.ingest(RideMetrics(speedKph: 36), at: t0 + .milliseconds(100))
        rec.ingest(RideMetrics(speedKph: 36), at: t0 + .seconds(1) + .milliseconds(100))
        #expect(abs(rec.distanceMeters - 10) < 0.001)   // 10 m/s × 1 s
        #expect(abs(rec.distanceMeters - rec.finish().summary().distanceMeters) < 0.001)
    }

    /// R-R intervals accumulate within a second (multiple HR notifications, each
    /// carrying beats) rather than overwriting like the scalar fields do.
    @Test func rrIntervalsAppendWithinSecond() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(heartRateBpm: 75, rrIntervalsSec: [0.80]),
                   at: t0 + .milliseconds(100))
        rec.ingest(RideMetrics(heartRateBpm: 76, rrIntervalsSec: [0.81, 0.79]),
                   at: t0 + .milliseconds(600))
        // A later reading with no R-R must not clear what was accumulated.
        rec.ingest(RideMetrics(powerW: 130), at: t0 + .milliseconds(900))

        let recording = rec.finish()
        #expect(recording.samples.count == 1)
        #expect(recording.samples[0].rrIntervalsSec == [0.80, 0.81, 0.79])
    }
}

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
}
