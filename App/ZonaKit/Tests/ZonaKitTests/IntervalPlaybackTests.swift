import Testing
@testable import ZonaKit

struct IntervalPlaybackTests {

    private let ftp = 200

    private func session(repeats: Int = 2,
                         workSeconds: Int = 30, workZone: PowerZone = .z5VO2Max,
                         restSeconds: Int = 30, restZone: PowerZone = .z1Recovery) -> IntervalSession {
        IntervalSession(
            name: "Test",
            repeats: repeats,
            work: IntervalStep(durationSeconds: workSeconds, zone: workZone),
            rest: IntervalStep(durationSeconds: restSeconds, zone: restZone))
    }

    private func workWatts(_ zone: PowerZone = .z5VO2Max) -> Int {
        ZoneEngine(ftp: ftp).steadyTarget(for: zone)
    }
    private func restWatts(_ zone: PowerZone = .z1Recovery) -> Int {
        ZoneEngine(ftp: ftp).steadyTarget(for: zone)
    }

    // MARK: Initial state

    @Test func startsIdle() {
        let playback = IntervalPlayback()
        #expect(playback.phase == .idle)
        #expect(playback.isRunning == false)
        #expect(playback.isCounting == false)
        #expect(playback.runningSession == nil)
        #expect(playback.lastCommandedWatts == nil)
    }

    @Test func tickWhileIdleDoesNothing() {
        var playback = IntervalPlayback()
        #expect(playback.tick(elapsed: 42, ftp: ftp) == [])
        #expect(playback.phase == .idle)
    }

    // MARK: Countdown

    @Test func beginCountdownArmsButDrivesNothing() {
        var playback = IntervalPlayback()
        let s = session()
        playback.beginCountdown(s, seconds: 15, preTargetW: 165)
        #expect(playback.isCounting)
        #expect(playback.phase == .countdown(session: s, remaining: 15, preTargetW: 165))
    }

    @Test func tickDecrementsCountdownWithoutStarting() {
        var playback = IntervalPlayback()
        let s = session()
        playback.beginCountdown(s, seconds: 3, preTargetW: 165)
        #expect(playback.tick(elapsed: 0, ftp: ftp) == [])
        #expect(playback.phase == .countdown(session: s, remaining: 2, preTargetW: 165))
        #expect(playback.tick(elapsed: 1, ftp: ftp) == [])
        #expect(playback.phase == .countdown(session: s, remaining: 1, preTargetW: 165))
    }

    @Test func countdownReachingZeroStartsTheBlockAndAppliesFirstStep() {
        var playback = IntervalPlayback()
        let s = session()
        playback.beginCountdown(s, seconds: 1, preTargetW: 165)
        // This tick takes remaining 1 -> 0, which starts the block at this elapsed.
        let actions = playback.tick(elapsed: 15, ftp: ftp)
        #expect(actions == [.setWatts(workWatts())])
        #expect(playback.isRunning)
        #expect(playback.runningSession == s)
        // The target armed with the countdown is carried into the running block,
        // so ending reverts *there* — not to the block's first-step watts.
        #expect(playback.phase == .running(session: s, startedAtSecond: 15, preTargetW: 165))
    }

    @Test func countdownRevertsToTheArmedTargetNotTheFirstStepWatts() {
        // The fix for the countdown revert fallback: the target in force when the
        // countdown was armed (a mid-ride trim to 140 W) must be what a finished
        // block reverts to, even though the caller passes it at arm time, not at
        // fire time.
        var playback = IntervalPlayback()
        let s = session(repeats: 1) // 1 x (30 + 30) = 60s once started
        playback.beginCountdown(s, seconds: 1, preTargetW: 140)
        _ = playback.tick(elapsed: 0, ftp: ftp) // fires the block at elapsed 0
        let actions = playback.tick(elapsed: 60, ftp: ftp) // block done
        #expect(actions.contains(.revert(toWatts: 140)))
    }

    @Test func cancelCountdownReturnsToIdle() {
        var playback = IntervalPlayback()
        playback.beginCountdown(session(), seconds: 10, preTargetW: 165)
        playback.cancelCountdown()
        #expect(playback.phase == .idle)
        #expect(playback.tick(elapsed: 5, ftp: ftp) == [])
    }

    @Test func beginCountdownIgnoredWhileAlreadyCounting() {
        var playback = IntervalPlayback()
        let first = session(repeats: 2)
        let second = session(repeats: 4)
        playback.beginCountdown(first, seconds: 15, preTargetW: 165)
        playback.beginCountdown(second, seconds: 15, preTargetW: 200)
        #expect(playback.phase == .countdown(session: first, remaining: 15, preTargetW: 165))
    }

    @Test func cancelWhileIdleIsANoOp() {
        var playback = IntervalPlayback()
        playback.cancelCountdown()
        #expect(playback.phase == .idle)
    }

    // MARK: Start captures the pre-block target

    @Test func startCapturesPreTargetAndAppliesFirstStep() {
        var playback = IntervalPlayback()
        // One session value reused: IntervalSession has a random UUID id, so
        // building it twice would compare unequal.
        let s = session()
        let actions = playback.start(s, atElapsed: 100, preTargetW: 165, ftp: ftp)
        #expect(actions == [.setWatts(workWatts())])
        #expect(playback.phase == .running(session: s, startedAtSecond: 100, preTargetW: 165))
        #expect(playback.lastCommandedWatts == workWatts())
    }

    @Test func startFallsBackToFirstStepWattsWhenCallerHasNoTarget() {
        var playback = IntervalPlayback()
        _ = playback.start(session(), atElapsed: 0, preTargetW: nil, ftp: ftp)
        if case let .running(_, _, preTargetW) = playback.phase {
            #expect(preTargetW == workWatts())
        } else {
            Issue.record("expected running phase")
        }
    }

    // MARK: Boundary-only setWatts

    @Test func tickWithinAStepEmitsNoWattsChange() {
        var playback = IntervalPlayback()
        _ = playback.start(session(), atElapsed: 0, preTargetW: 165, ftp: ftp)
        // Still inside the first 30s work step: no boundary, no new command.
        #expect(playback.tick(elapsed: 1, ftp: ftp) == [])
        #expect(playback.tick(elapsed: 29, ftp: ftp) == [])
    }

    @Test func crossingIntoRestEmitsTheRestWatts() {
        var playback = IntervalPlayback()
        _ = playback.start(session(), atElapsed: 0, preTargetW: 165, ftp: ftp)
        // 30s work then 30s rest: at elapsed 30 we cross into rest.
        #expect(playback.tick(elapsed: 30, ftp: ftp) == [.setWatts(restWatts())])
        #expect(playback.lastCommandedWatts == restWatts())
    }

    @Test func startedMidRideUsesElapsedSinceStartNotAbsolute() {
        var playback = IntervalPlayback()
        // Block starts at recorder second 500.
        _ = playback.start(session(), atElapsed: 500, preTargetW: 165, ftp: ftp)
        // 29s in — still work.
        #expect(playback.tick(elapsed: 529, ftp: ftp) == [])
        // 30s in — cross to rest.
        #expect(playback.tick(elapsed: 530, ftp: ftp) == [.setWatts(restWatts())])
    }

    // MARK: Natural finish — record then revert, to the pre-block target

    @Test func blockFinishingRecordsThenRevertsToPreBlockTarget() {
        var playback = IntervalPlayback()
        let s = session(repeats: 2) // 2 x (30 + 30) = 120s
        _ = playback.start(s, atElapsed: 0, preTargetW: 165, ftp: ftp)
        // At elapsed 120 the block is done.
        let actions = playback.tick(elapsed: 120, ftp: ftp)
        #expect(actions == [
            .recordRun(session: s, startedAtSecond: 0, actualSeconds: 120),
            .revert(toWatts: 165),
        ])
        #expect(playback.phase == .idle)
        #expect(playback.lastCommandedWatts == nil)
    }

    @Test func recordComesBeforeRevertInTheReturnedOrder() {
        var playback = IntervalPlayback()
        _ = playback.start(session(repeats: 1), atElapsed: 0, preTargetW: 150, ftp: ftp)
        let actions = playback.tick(elapsed: 60, ftp: ftp) // 1 x (30+30) done at 60
        // The ordering is load-bearing: the run must be banked before the target
        // is restored (finish() locks the recording in the app).
        guard actions.count == 2 else { Issue.record("expected two actions"); return }
        if case .recordRun = actions[0] {} else { Issue.record("first action must be recordRun") }
        if case .revert = actions[1] {} else { Issue.record("second action must be revert") }
    }

    @Test func revertUsesTheTrimmedTargetNotTheComputedSteadyValue() {
        // The load-bearing invariant from 30476e0: a mid-ride TargetAdjuster trim
        // (say the rider dropped to 140 W) is what's captured as preTargetW, so
        // ending reverts *there*, not to settings.target.
        var playback = IntervalPlayback()
        _ = playback.start(session(repeats: 1), atElapsed: 0, preTargetW: 140, ftp: ftp)
        let actions = playback.tick(elapsed: 60, ftp: ftp)
        #expect(actions.contains(.revert(toWatts: 140)))
    }

    // MARK: Stopping early

    @Test func stopEarlyRecordsTheShorterActualLengthThenReverts() {
        var playback = IntervalPlayback()
        let s = session(repeats: 4) // authored 4 x (30+30) = 240s
        _ = playback.start(s, atElapsed: 10, preTargetW: 170, ftp: ftp)
        // Rider stops at recorder second 55: actual run is 45s, not the full 240.
        let actions = playback.stop(atElapsed: 55)
        #expect(actions == [
            .recordRun(session: s, startedAtSecond: 10, actualSeconds: 45),
            .revert(toWatts: 170),
        ])
        #expect(playback.phase == .idle)
    }

    @Test func stopWhileNotRunningIsANoOp() {
        var playback = IntervalPlayback()
        #expect(playback.stop(atElapsed: 100) == [])
        playback.beginCountdown(session(), seconds: 15, preTargetW: 165)
        // Even mid-countdown, stop() only ends a *running* block.
        #expect(playback.stop(atElapsed: 100) == [])
        #expect(playback.isCounting)
    }

    // MARK: currentState mirror

    @Test func currentStateMirrorsSchedulerWhileRunning() {
        var playback = IntervalPlayback()
        _ = playback.start(session(), atElapsed: 100, preTargetW: 165, ftp: ftp)
        let state = playback.currentState(elapsed: 100, ftp: ftp)
        #expect(state?.stepIndex == 0)
        #expect(state?.zone == .z5VO2Max)
        #expect(state?.secondsRemainingInStep == 30)
    }

    @Test func currentStateIsNilWhenIdleOrCounting() {
        var playback = IntervalPlayback()
        #expect(playback.currentState(elapsed: 0, ftp: ftp) == nil)
        playback.beginCountdown(session(), seconds: 15, preTargetW: 165)
        #expect(playback.currentState(elapsed: 0, ftp: ftp) == nil)
    }

    // MARK: Degenerate sessions (editor prevents these; guard anyway)

    @Test func startingAZeroRepeatSessionEndsImmediatelyAndReverts() {
        var playback = IntervalPlayback()
        let s = session(repeats: 0)
        let actions = playback.start(s, atElapsed: 0, preTargetW: 155, ftp: ftp)
        // No steps to run: record a zero-length run and revert straight back.
        #expect(actions == [
            .recordRun(session: s, startedAtSecond: 0, actualSeconds: 0),
            .revert(toWatts: 155),
        ])
        #expect(playback.phase == .idle)
    }
}
