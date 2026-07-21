import Testing
@testable import ZonaKit

struct IntervalSchedulerTests {

    private func session(repeats: Int = 2,
                         workSeconds: Int = 30, workZone: PowerZone = .z5VO2Max,
                         restSeconds: Int = 30, restZone: PowerZone = .z1Recovery) -> IntervalSession {
        IntervalSession(
            name: "Test",
            repeats: repeats,
            work: IntervalStep(durationSeconds: workSeconds, zone: workZone),
            rest: IntervalStep(durationSeconds: restSeconds, zone: restZone))
    }

    // MARK: Step boundary transitions

    @Test func firstSecondIsTheFirstWorkStep() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        let state = scheduler.target(atSecond: 0)
        #expect(state?.repeatIndex == 0)
        #expect(state?.isWork == true)
        #expect(state?.secondsRemainingInStep == 30)
    }

    @Test func lastSecondOfWorkStepStillReportsWork() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        let state = scheduler.target(atSecond: 29)
        #expect(state?.isWork == true)
        #expect(state?.secondsRemainingInStep == 1)
    }

    @Test func crossingIntoRestAtTheExactBoundary() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        let state = scheduler.target(atSecond: 30)
        #expect(state?.isWork == false)
        #expect(state?.repeatIndex == 0)
        #expect(state?.secondsRemainingInStep == 30)
    }

    @Test func secondRepeatStartsAfterFirstWorkRestPair() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        let state = scheduler.target(atSecond: 60)
        #expect(state?.repeatIndex == 1)
        #expect(state?.isWork == true)
        #expect(state?.totalRepeats == 2)
    }

    // MARK: Watts computed from zone + FTP

    @Test func targetWattsMatchesZoneEngineSteadyTarget() {
        let scheduler = IntervalScheduler(
            session: session(workZone: .z5VO2Max, restZone: .z1Recovery), ftp: 200)
        let work = scheduler.target(atSecond: 0)
        #expect(work?.targetWatts == ZoneEngine(ftp: 200).steadyTarget(for: .z5VO2Max))

        let rest = scheduler.target(atSecond: 30)
        #expect(rest?.targetWatts == ZoneEngine(ftp: 200).steadyTarget(for: .z1Recovery))
    }

    // MARK: Finishing

    @Test func returnsNilOnceTheBlockFinishes() {
        let scheduler = IntervalScheduler(session: session(repeats: 2), ftp: 200)
        // 2 x (30s + 30s) = 120s total.
        #expect(scheduler.target(atSecond: 119) != nil)
        #expect(scheduler.target(atSecond: 120) == nil)
        #expect(scheduler.target(atSecond: 500) == nil)
    }

    // MARK: Degenerate inputs (defensive — the editor is expected to prevent these)

    @Test func zeroRepeatsFinishesImmediately() {
        let scheduler = IntervalScheduler(session: session(repeats: 0), ftp: 200)
        #expect(scheduler.target(atSecond: 0) == nil)
    }

    @Test func negativeRepeatsFinishesImmediately() {
        let scheduler = IntervalScheduler(session: session(repeats: -1), ftp: 200)
        #expect(scheduler.target(atSecond: 0) == nil)
    }

    @Test func zeroDurationStepsAreSkippedInstantlyWithoutStalling() {
        // Zero-second work, 10s rest, twice: should behave as if work never
        // happened rather than getting stuck offering a zero-length work step.
        let scheduler = IntervalScheduler(
            session: session(repeats: 2, workSeconds: 0, restSeconds: 10), ftp: 200)
        let state = scheduler.target(atSecond: 0)
        #expect(state?.isWork == false)
        #expect(state?.secondsRemainingInStep == 10)
        #expect(scheduler.target(atSecond: 20) == nil)
    }

    @Test func negativeElapsedReturnsNil() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        #expect(scheduler.target(atSecond: -1) == nil)
    }
}
