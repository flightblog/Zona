import Testing
@testable import ZonaKit

@Suite("Interval achievement")
struct IntervalAchievementTests {

    /// 2×(2s Z5 / 2s Z1), so each step is a two-second window that's easy to
    /// attribute by eye.
    private func session(repeats: Int = 2, work: Int = 2, rest: Int = 2) -> IntervalSession {
        IntervalSession(name: "Test",
                        repeats: repeats,
                        work: IntervalStep(durationSeconds: work, zone: .z5VO2Max),
                        rest: IntervalStep(durationSeconds: rest, zone: .z1Recovery))
    }

    private func sample(_ second: Int, power: Int? = nil, meter: Int? = nil, hr: Int? = nil) -> RideSample {
        var s = RideSample(secondsFromStart: second)
        s.powerW = power
        s.powerMeterW = meter
        s.heartRateBpm = hr
        return s
    }

    @Test("Splits a run into one entry per work and rest step, in ride order")
    func perStepOrdering() {
        let run = IntervalRun(session: session(), startedAtSecond: 0, actualSeconds: 8)
        let got = IntervalAchievement.perStep(run: run, samples: [])

        #expect(got.count == 4)
        #expect(got.map(\.stepIndex) == [0, 1, 2, 3])
        #expect(got.map(\.zone) == [.z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery])
        #expect(got.allSatisfy { $0.seconds == 2 })
    }

    /// The core attribution guarantee: a sample lands in the step whose window
    /// contains its second, on the same boundaries the scheduler drove ERG on.
    @Test("Attributes samples to the step whose window contains them")
    func windowsSamplesPerStep() {
        let run = IntervalRun(session: session(), startedAtSecond: 0, actualSeconds: 8)
        let samples = [
            sample(0, power: 300), sample(1, power: 310),   // rep 0 work
            sample(2, power: 100), sample(3, power: 110),   // rep 0 rest
            sample(4, power: 280), sample(5, power: 290),   // rep 1 work
            sample(6, power: 120), sample(7, power: 130),   // rep 1 rest
        ]
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got.map(\.avgPowerW) == [305, 105, 285, 125])
        #expect(got.map(\.maxPowerW) == [310, 110, 290, 130])
    }

    /// A boundary second belongs to exactly one step. If the window were closed
    /// at both ends, second 2 would count into both rep 0's work and its rest.
    @Test("Does not double-count the second on a step boundary")
    func boundarySecondBelongsToOneStep() {
        let run = IntervalRun(session: session(repeats: 1), startedAtSecond: 0, actualSeconds: 4)
        let samples = [sample(0, power: 300), sample(1, power: 300),
                       sample(2, power: 100), sample(3, power: 100)]
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got[0].avgPowerW == 300)   // work: seconds 0–1 only
        #expect(got[1].avgPowerW == 100)   // rest: seconds 2–3 only
    }

    /// Samples live on the ride's axis, the run on its own — the offset has to
    /// be applied or every rep reads the wrong slice.
    @Test("Offsets the run's window by startedAtSecond onto the ride axis")
    func offsetsByStartSecond() {
        let run = IntervalRun(session: session(repeats: 1), startedAtSecond: 600, actualSeconds: 4)
        let samples = [
            sample(599, power: 999),                        // before the run
            sample(600, power: 300), sample(601, power: 300),
            sample(602, power: 100), sample(603, power: 100),
            sample(604, power: 999),                        // after the run
        ]
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got[0].avgPowerW == 300)
        #expect(got[1].avgPowerW == 100)
    }

    @Test("Reports steps the run reached, omitting those it never started")
    func omitsUnreachedSteps() {
        // 2×(2/2) = 8s authored, stopped after 5s: rep 0 complete, rep 1's work
        // partially ridden, rep 1's rest never started.
        let run = IntervalRun(session: session(), startedAtSecond: 0, actualSeconds: 5)
        let got = IntervalAchievement.perStep(run: run, samples: [])

        #expect(got.count == 3)
        #expect(got.map(\.seconds) == [2, 2, 1])
    }

    @Test("Clamps a partially-ridden final step to the seconds it ran")
    func clampsPartialStep() {
        let run = IntervalRun(session: session(), startedAtSecond: 0, actualSeconds: 5)
        let samples = [sample(4, power: 250)]           // the one second of rep 1's work
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got.last?.seconds == 1)
        #expect(got.last?.avgPowerW == 250)
    }

    /// "No reading" and "zero watts" are different claims — a step with no
    /// samples must not report 0.
    @Test("Reports nil, not zero, for a step with no readings")
    func nilForMissingReadings() {
        let run = IntervalRun(session: session(repeats: 1), startedAtSecond: 0, actualSeconds: 4)
        let got = IntervalAchievement.perStep(run: run, samples: [])

        #expect(got[0].avgPowerW == nil)
        #expect(got[0].maxPowerW == nil)
        #expect(got[0].avgHeartRateBpm == nil)
        #expect(got[0].isEmpty)
    }

    /// The crank meter expires on a coast, so its channel goes nil mid-step
    /// while the trainer keeps reporting. Averaging must skip the gaps rather
    /// than treating them as 0 — see `RideMetrics.powerMeterW`.
    @Test("Averages leg power over reporting seconds only, ignoring expired gaps")
    func legPowerIgnoresExpiredSeconds() {
        let run = IntervalRun(session: session(repeats: 1, work: 4, rest: 1),
                              startedAtSecond: 0, actualSeconds: 4)
        let samples = [
            sample(0, power: 300, meter: 310),
            sample(1, power: 300, meter: nil),   // meter expired on a coast
            sample(2, power: 300, meter: nil),
            sample(3, power: 300, meter: 330),
        ]
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got[0].avgPowerW == 300)
        #expect(got[0].avgPowerMeterW == 320)   // (310+330)/2, not /4
        #expect(got[0].maxPowerMeterW == 330)
    }

    @Test("Reports no leg power at all when no meter was paired")
    func noMeterMeansNilLegPower() {
        let run = IntervalRun(session: session(repeats: 1), startedAtSecond: 0, actualSeconds: 4)
        let samples = [sample(0, power: 300, hr: 150), sample(1, power: 300, hr: 152)]
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got[0].avgPowerW == 300)
        #expect(got[0].avgPowerMeterW == nil)
        #expect(got[0].maxPowerMeterW == nil)
        #expect(!got[0].isEmpty)          // trainer + HR still present
    }

    @Test("Carries heart rate through per step")
    func heartRatePerStep() {
        let run = IntervalRun(session: session(repeats: 1), startedAtSecond: 0, actualSeconds: 4)
        let samples = [sample(0, hr: 140), sample(1, hr: 150),
                       sample(2, hr: 160), sample(3, hr: 170)]
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got[0].avgHeartRateBpm == 145)
        #expect(got[0].maxHeartRateBpm == 150)
        #expect(got[1].avgHeartRateBpm == 165)
        #expect(got[1].maxHeartRateBpm == 170)
    }

    /// The summary's `avg bpm` column reads `avgHeartRateBpm`. A late spike must
    /// move the average only a little while moving the peak a lot — so if the two
    /// are ever swapped at the call site, this asserts they're distinguishable
    /// and which one represents the step.
    @Test("Average heart rate is not the step's peak")
    func averageHeartRateIsDistinctFromPeak() {
        let run = IntervalRun(session: session(repeats: 1, work: 4, rest: 1),
                              startedAtSecond: 0, actualSeconds: 4)
        // Steady 140 with one 180 spike: avg 150, max 180.
        let samples = [sample(0, hr: 140), sample(1, hr: 140),
                       sample(2, hr: 140), sample(3, hr: 180)]
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got[0].avgHeartRateBpm == 150)
        #expect(got[0].maxHeartRateBpm == 180)
    }

    @Test("Rounds an average to nearest rather than truncating")
    func roundsAverage() {
        let run = IntervalRun(session: session(repeats: 1), startedAtSecond: 0, actualSeconds: 4)
        // 300, 301, 301 → 300.67 → 301
        let samples = [sample(0, power: 300), sample(1, power: 301)]
        let got = IntervalAchievement.perStep(run: run,
                                              samples: samples + [sample(1, power: 301)])
        #expect(got[0].avgPowerW == 301)
    }

    @Test("Returns nothing for a run that never ran")
    func emptyForZeroLengthRun() {
        let run = IntervalRun(session: session(), startedAtSecond: 0, actualSeconds: 0)
        #expect(IntervalAchievement.perStep(run: run, samples: []).isEmpty)
    }

    @Test("Returns nothing for a degenerate session with no steps")
    func emptyForSessionWithoutSteps() {
        let run = IntervalRun(session: session(repeats: 0), startedAtSecond: 0, actualSeconds: 10)
        #expect(IntervalAchievement.perStep(run: run, samples: []).isEmpty)
    }

    /// Zero-duration steps are skipped without stalling the walk, mirroring
    /// `IntervalScheduler.target(atSecond:)`'s defensive handling.
    @Test("Skips zero-duration steps without consuming the run")
    func skipsZeroDurationSteps() {
        let run = IntervalRun(session: session(repeats: 1, work: 0, rest: 3),
                              startedAtSecond: 0, actualSeconds: 3)
        let got = IntervalAchievement.perStep(run: run, samples: [sample(0, power: 120)])

        #expect(got.count == 1)
        #expect(got[0].zone == .z1Recovery)
        #expect(got[0].seconds == 3)
    }

    /// The run's window is a slice of the ride, so samples from elsewhere in the
    /// ride must not leak in — callers pass `ride.samples` wholesale.
    @Test("Ignores samples outside the run's window")
    func ignoresSamplesOutsideRun() {
        let run = IntervalRun(session: session(repeats: 1), startedAtSecond: 10, actualSeconds: 4)
        let samples = (0..<30).map { sample($0, power: $0 < 10 || $0 >= 14 ? 999 : 200) }
        let got = IntervalAchievement.perStep(run: run, samples: samples)

        #expect(got[0].avgPowerW == 200)
        #expect(got[1].avgPowerW == 200)
        #expect(got.allSatisfy { ($0.maxPowerW ?? 0) < 999 })
    }
}
