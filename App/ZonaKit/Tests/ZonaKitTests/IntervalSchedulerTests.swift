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
        #expect(state?.stepIndex == 0)
        #expect(state?.zone == .z5VO2Max)
        #expect(state?.secondsRemainingInStep == 30)
    }

    @Test func lastSecondOfWorkStepStillReportsWork() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        let state = scheduler.target(atSecond: 29)
        #expect(state?.zone == .z5VO2Max)
        #expect(state?.secondsRemainingInStep == 1)
    }

    @Test func crossingIntoRestAtTheExactBoundary() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        let state = scheduler.target(atSecond: 30)
        #expect(state?.stepIndex == 1)
        #expect(state?.zone == .z1Recovery)
        #expect(state?.secondsRemainingInStep == 30)
    }

    @Test func secondRepeatStartsAfterFirstWorkRestPair() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        let state = scheduler.target(atSecond: 60)
        #expect(state?.stepIndex == 2)
        #expect(state?.zone == .z5VO2Max)
        #expect(state?.totalSteps == 4)
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
        #expect(state?.zone == .z1Recovery)
        #expect(state?.secondsRemainingInStep == 10)
        #expect(scheduler.target(atSecond: 20) == nil)
    }

    @Test func negativeElapsedReturnsNil() {
        let scheduler = IntervalScheduler(session: session(), ftp: 200)
        #expect(scheduler.target(atSecond: -1) == nil)
    }

    // MARK: Repeat position (what the ride HUD counts for a uniform set)

    @Test func uniformSetReportsRepeatPositionThroughTheSet() {
        let scheduler = IntervalScheduler(session: session(repeats: 4), ftp: 200)

        let firstWork = scheduler.target(atSecond: 0)?.repetition
        #expect(firstWork?.index == 0)
        #expect(firstWork?.total == 4)
        #expect(firstWork?.isWork == true)

        let firstRest = scheduler.target(atSecond: 30)?.repetition
        #expect(firstRest?.index == 0)
        #expect(firstRest?.isWork == false)

        let thirdWork = scheduler.target(atSecond: 120)?.repetition
        #expect(thirdWork?.index == 2)
        #expect(thirdWork?.isWork == true)

        let lastRest = scheduler.target(atSecond: 210)?.repetition
        #expect(lastRest?.index == 3)
        #expect(lastRest?.isWork == false)
    }

    /// A free-form session has no reps to count, so the HUD falls back to steps.
    @Test func freeFormSessionReportsNoRepeatPosition() {
        let s = IntervalSession(name: "Pyramid", steps: [
            IntervalStep(durationSeconds: 300, zone: .z2Endurance),
            IntervalStep(durationSeconds: 60, zone: .z4Threshold),
            IntervalStep(durationSeconds: 120, zone: .z5VO2Max),
        ])
        let scheduler = IntervalScheduler(session: s, ftp: 200)
        #expect(scheduler.target(atSecond: 0)?.repetition == nil)
        #expect(scheduler.target(atSecond: 350)?.repetition == nil)
    }

    /// All-identical steps are NOT a work/rest set — there's no rest to speak
    /// of. Treating them as one would have the HUD label alternate steps "REST"
    /// while the rider holds exactly the same zone throughout.
    @Test func allIdenticalStepsReportNoRepeatPosition() {
        let steps = (0..<4).map { _ in IntervalStep(durationSeconds: 60, zone: .z2Endurance) }
        let scheduler = IntervalScheduler(session: IntervalSession(name: "x", steps: steps),
                                          ftp: 200)
        #expect(scheduler.target(atSecond: 0)?.repetition == nil)
        #expect(scheduler.target(atSecond: 90)?.repetition == nil)
    }

    /// A set with a cooldown appended is no longer a uniform alternation, so it
    /// counts steps rather than mislabelling the cooldown as a rep.
    @Test func setWithACooldownReportsNoRepeatPosition() {
        var steps = (0..<2).flatMap { _ in
            [IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
             IntervalStep(durationSeconds: 30, zone: .z1Recovery)]
        }
        steps.append(IntervalStep(durationSeconds: 600, zone: .z2Endurance))
        let scheduler = IntervalScheduler(session: IntervalSession(name: "x", steps: steps),
                                          ftp: 200)
        #expect(scheduler.target(atSecond: 0)?.repetition == nil)
        #expect(scheduler.target(atSecond: 0)?.totalSteps == 5)
    }
}
