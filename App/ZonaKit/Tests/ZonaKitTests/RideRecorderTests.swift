import Foundation
import Testing
@testable import ZonaKit

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
