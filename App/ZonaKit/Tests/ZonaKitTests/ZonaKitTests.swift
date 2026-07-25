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

    /// The power bands are inclusive at BOTH ends and touch at their boundaries —
    /// at FTP 200, Z1 is 0…110 and Z2 is 110…150, so 110 belongs to two bands.
    /// `zone(forPower:)` is the tiebreak (`fraction <= upperFraction` in
    /// `PowerZone.allCases` order, so the LOWER zone wins the shared edge), and
    /// it's the only correct classifier. This is the power-side twin of the HR
    /// trap that `RideHRZoningTests.classifyingByBandScanWouldLandOnTheWrongZone`
    /// pins — scanning `wattRange`s to classify would be wrong here too, since
    /// Z1's band starts at 0 and underlaps every other band's floor.
    @Test func classifyPowerAtSharedBandEdges() {
        // Every shared edge lands in the lower of the two zones.
        #expect(engine.zone(forPower: 110) == .z1Recovery)   // Z1/Z2 edge
        #expect(engine.zone(forPower: 150) == .z2Endurance)  // Z2/Z3 edge
        #expect(engine.zone(forPower: 180) == .z3Tempo)      // Z3/Z4 edge
        #expect(engine.zone(forPower: 210) == .z4Threshold)  // Z4/Z5 edge
        #expect(engine.zone(forPower: 240) == .z5VO2Max)     // Z5/Z6 edge
        #expect(engine.zone(forPower: 300) == .z6Anaerobic)  // Z6/Z7 edge

        // One watt past each edge crosses into the upper zone.
        #expect(engine.zone(forPower: 111) == .z2Endurance)
        #expect(engine.zone(forPower: 151) == .z3Tempo)
        #expect(engine.zone(forPower: 181) == .z4Threshold)
        #expect(engine.zone(forPower: 211) == .z5VO2Max)
        #expect(engine.zone(forPower: 241) == .z6Anaerobic)
        #expect(engine.zone(forPower: 301) == .z7Neuromuscular)

        // Z1's band starts at 0, so it underlaps every other band's floor.
        #expect(engine.wattRange(for: .z1Recovery).lowerBound == 0)
        #expect(engine.zone(forPower: 0) == .z1Recovery)
    }

    /// Z7 has an infinite upper fraction, so it's the catch-all: no wattage,
    /// however implausible, classifies past it or falls through to a crash.
    @Test func z7AbsorbsEverythingAboveItsFloor() {
        #expect(engine.zone(forPower: 400) == .z7Neuromuscular)
        #expect(engine.zone(forPower: 2000) == .z7Neuromuscular)
        // `wattRange` substitutes 2×FTP for the infinite bound so the band is
        // renderable rather than unbounded.
        #expect(engine.wattRange(for: .z7Neuromuscular) == 300...400)
    }

    /// A zero/absent FTP (fresh install before the rider sets one) must not
    /// divide by zero — classification degrades to Z1 rather than crashing.
    @Test func zeroFTPClassifiesAsZ1WithoutDividingByZero() {
        let unset = ZoneEngine(ftp: 0)
        #expect(unset.zone(forPower: 0) == .z1Recovery)
        #expect(unset.zone(forPower: 250) == .z1Recovery)
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

    /// `elapsed(at:)` ticks off the monotonic start instant directly, unlike
    /// `elapsedSeconds` (which only advances on `ingest`) — so a UI timer can
    /// keep counting from its own periodic clock even while the trainer is
    /// silent and nothing has been ingested yet.
    @Test func elapsedAtReflectsWallClockWithoutIngest() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        #expect(rec.elapsed(at: t0 + .seconds(7) + .milliseconds(200)) == 7)
    }

    /// Once recording stops, `elapsed(at:)` must return the frozen
    /// `elapsedSeconds` rather than keep computing from the (now stale) start
    /// instant — otherwise a UI timer still ticking after `finish()` would show
    /// live time drifting past the ride's actual duration.
    @Test func elapsedAtFreezesAfterFinish() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 100), at: t0 + .seconds(3))
        rec.finish(at: t0 + .seconds(5))
        #expect(rec.elapsed(at: t0 + .seconds(60)) == 5)   // ignores the later instant
    }

    /// A negative second (an `at:` before `start`'s clock instant — e.g. clock
    /// skew) must be dropped rather than recorded under a bogus bucket or
    /// crash on the dictionary lookup.
    @Test func ingestIgnoresInstantBeforeStart() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 999), at: t0 - .seconds(1))
        #expect(rec.finish().samples.isEmpty)
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

    /// Crank-meter watts record onto their own field, on the same last-write-wins
    /// terms as the other scalars — and never bleed into the trainer's `powerW`.
    @Test func recordsPowerMeterAlongsideTrainerPower() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 150, powerMeterW: 156), at: t0 + .milliseconds(100))
        rec.ingest(RideMetrics(powerW: 152, powerMeterW: 159), at: t0 + .milliseconds(900))

        let recording = rec.finish()
        #expect(recording.samples.count == 1)
        #expect(recording.samples[0].powerW == 152)        // trainer, untouched
        #expect(recording.samples[0].powerMeterW == 159)   // meter, its own channel
    }

    /// A ride with no meter paired leaves every sample's `powerMeterW` nil — the
    /// trainer's power still records normally.
    @Test func noPowerMeterLeavesSamplesNil() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 150), at: t0 + .milliseconds(100))

        let recording = rec.finish()
        #expect(recording.samples[0].powerW == 150)
        #expect(recording.samples[0].powerMeterW == nil)
    }

    /// A rider who coasts must not bank leg power for the seconds they weren't
    /// pedalling. `SensorHub` expires a quiet meter's watts to nil, but that only
    /// helps if `ingest` *applies* the nil: skipping it (as the other scalars do)
    /// would let the second keep its last wattage, and the 1 Hz re-ingest would
    /// re-bank it every second. The trainer's own power keeps recording normally.
    @Test func coastingClearsPowerMeterRatherThanFreezingIt() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)

        // Pedalling: meter reports alongside the trainer.
        rec.ingest(RideMetrics(powerW: 240, powerMeterW: 250), at: t0)
        // Coasting: trainer keeps streaming a real 0 W, the meter has gone quiet
        // and the hub has expired it to nil.
        rec.ingest(RideMetrics(powerW: 0, powerMeterW: nil), at: t0 + .seconds(1))

        let recording = rec.finish(at: t0 + .seconds(2))
        #expect(recording.samples[0].powerMeterW == 250)
        #expect(recording.samples[1].powerMeterW == nil)   // not frozen at 250
        #expect(recording.samples[1].powerW == 0)          // trainer still recorded
    }

    /// The same clearing has to hold *within* a second: the meter can report early
    /// in a second and go quiet before the 1 Hz re-ingest lands in that same
    /// second. The bucket must end up nil, not hold the earlier reading.
    @Test func powerMeterClearsWithinTheSameSecond() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 240, powerMeterW: 250), at: t0 + .milliseconds(100))
        rec.ingest(RideMetrics(powerW: 0, powerMeterW: nil), at: t0 + .milliseconds(900))

        let recording = rec.finish(at: t0 + .seconds(1))
        #expect(recording.samples[0].powerMeterW == nil)
        #expect(recording.samples[0].powerW == 0)
    }

    private func session() -> IntervalSession {
        IntervalSession(
            name: "4 x 30/30",
            repeats: 4,
            work: IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
            rest: IntervalStep(durationSeconds: 30, zone: .z1Recovery))
    }

    /// Interval runs logged during the ride flow into the finished recording, in
    /// the order they started, carrying the start second and actual length the
    /// caller passed. A steady ride records none.
    @Test func recordsIntervalRunsInStartOrder() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 150), at: t0 + .seconds(1))
        rec.recordInterval(session(), startedAtSecond: 60, actualSeconds: 240)
        rec.recordInterval(session(), startedAtSecond: 400, actualSeconds: 90)

        let recording = rec.finish(at: t0 + .seconds(600))
        #expect(recording.intervalRuns.count == 2)
        #expect(recording.intervalRuns[0].startedAtSecond == 60)
        #expect(recording.intervalRuns[0].completed)          // full 240s
        #expect(recording.intervalRuns[1].startedAtSecond == 400)
        #expect(!recording.intervalRuns[1].completed)         // stopped at 90s
    }

    /// A ride that ran no interval session carries an empty `intervalRuns`, so the
    /// summary hides its interval section.
    @Test func steadyRideRecordsNoIntervalRuns() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 150), at: t0 + .seconds(1))
        #expect(rec.finish(at: t0 + .seconds(2)).intervalRuns.isEmpty)
    }

    /// `start` clears runs from a prior ride, and a `recordInterval` after
    /// `finish()` is a no-op (recording is locked), so a stray late call can't
    /// mutate a finished ride.
    @Test func startClearsRunsAndRecordIsNoOpAfterFinish() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.recordInterval(session(), startedAtSecond: 10, actualSeconds: 240)
        let recording = rec.finish(at: t0 + .seconds(300))
        #expect(recording.intervalRuns.count == 1)

        // After finish: recording locked, so this is dropped.
        rec.recordInterval(session(), startedAtSecond: 5, actualSeconds: 60)
        // And a fresh ride starts with no runs carried over.
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        #expect(rec.finish(at: t0 + .seconds(1)).intervalRuns.isEmpty)
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
}
