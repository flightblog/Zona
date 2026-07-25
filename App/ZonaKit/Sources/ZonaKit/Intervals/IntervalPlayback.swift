import Foundation

/// Drives one interval session through its lifecycle on the ride screen:
/// `idle` → `countdown` → `running` → `idle`. Pure and value-typed, so the whole
/// countdown/start/revert flow is unit-testable in `ZonaKit` without running the
/// app — the same split as `RideSettingsState` (decision logic here, thin
/// `@Observable`/view wrapper in the app).
///
/// This owns only the *playback orchestration* — the get-ready countdown, when
/// the block starts and ends, the ERG-write-only-on-boundary logic, and the
/// revert-to-pre-block-target rule. The step-by-step "what watts right now" math
/// stays in `IntervalScheduler`, which this calls into.
///
/// It never touches the trainer, recorder, or settings itself. Instead it takes
/// the values it needs as *inputs* at each transition (elapsed second, the ERG
/// target in force, the FTP) and returns intents — `Action`s — for the view to
/// apply. That keeps the recorder mutation (`recordRun`) and the ERG writes on
/// the caller's side, and makes the "record the finished run *before* reverting
/// the target" ordering a property of this struct (the returned array order)
/// rather than a convention held by a comment in the view.
public struct IntervalPlayback: Sendable, Equatable {

    /// Where playback is in its lifecycle. The old `RideView` encoded this
    /// implicitly across six correlated optionals; here it's one explicit enum,
    /// so illegal combinations (e.g. a countdown *and* a running block) can't be
    /// represented.
    public enum Phase: Sendable, Equatable {
        /// Nothing armed: the manual `TargetAdjuster` owns the target.
        case idle
        /// A session was chosen and is settling in a "get ready" countdown
        /// before its first block drives ERG. Cancelable. `preTargetW` is the ERG
        /// target in force when the countdown was armed (including any mid-ride
        /// `TargetAdjuster` trim); it's carried into `running` so ending reverts
        /// to it rather than to the computed steady value — captured now because
        /// the caller knows it when arming, not when the countdown fires.
        case countdown(session: IntervalSession, remaining: Int, preTargetW: Int?)
        /// A block is actively steering ERG. `startedAtSecond` is the recorder
        /// second it began at (so elapsed-since-start can be recomputed each
        /// tick), and `preTargetW` is the ERG target that was in force the
        /// instant it started — reverted to on end so a mid-ride `TargetAdjuster`
        /// trim survives, rather than snapping back to the computed steady value.
        case running(session: IntervalSession, startedAtSecond: Int, preTargetW: Int)
    }

    /// An intent for the caller to apply. The struct returns these instead of
    /// reaching into the trainer/recorder, so its logic stays pure and the side
    /// effects (BLE writes, recorder mutation) stay testable-in-isolation on the
    /// view's side. Callers apply a returned `[Action]` *in order*.
    public enum Action: Sendable, Equatable {
        /// Push this ERG setpoint to the trainer. Emitted only when the target
        /// actually changed at a step boundary, never every tick.
        case setWatts(Int)
        /// Restore the pre-block ERG target when a block ends.
        case revert(toWatts: Int)
        /// Bank the finished (or stopped-early) run so it shows on the summary.
        /// Always emitted *before* the accompanying `revert` in the returned
        /// array, mirroring `endInterval`'s record-then-revert order.
        case recordRun(session: IntervalSession, startedAtSecond: Int, actualSeconds: Int)
    }

    public private(set) var phase: Phase
    /// The watts last pushed to the trainer for the running block, so a tick only
    /// emits `setWatts` at a step boundary rather than every second. nil whenever
    /// no block is running (reset on start and on end).
    public private(set) var lastCommandedWatts: Int?

    public init() {
        phase = .idle
        lastCommandedWatts = nil
    }

    /// True while a block is actively steering ERG — the ride screen shows the
    /// `IntervalHUD` and disables Add intervals in this state.
    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// True while a chosen session is counting down but hasn't started — the ride
    /// screen shows the `IntervalCountdownHUD` and still disables Add intervals.
    public var isCounting: Bool {
        if case .countdown = phase { return true }
        return false
    }

    /// The running session, if any — for the caller to key its HUD off.
    public var runningSession: IntervalSession? {
        if case let .running(session, _, _) = phase { return session }
        return nil
    }

    /// The session settling in a countdown, if any — for the countdown HUD's name.
    public var countingSession: IntervalSession? {
        if case let .countdown(session, _, _) = phase { return session }
        return nil
    }

    /// Seconds left in the "get ready" countdown, or nil when not counting down —
    /// for the countdown HUD's number.
    public var countdownRemaining: Int? {
        if case let .countdown(_, remaining, _) = phase { return remaining }
        return nil
    }

    // MARK: Countdown

    /// Arm a chosen session with a "get ready" countdown of `seconds` before its
    /// first block drives ERG, so the picker dismissing doesn't snap the ERG up
    /// instantly. No-op (and no action) if a countdown or block is already
    /// active — the ride screen disables Add intervals then, but guard anyway.
    ///
    /// `preTargetW` is the ERG target in force right now (the caller's current
    /// setpoint, e.g. `controller.metrics.targetW ?? settings.target`, including
    /// any manual trim). It's captured here rather than when the countdown fires
    /// so ending the block reverts to where the rider actually was, not to the
    /// block's first-step watts.
    public mutating func beginCountdown(_ session: IntervalSession, seconds: Int, preTargetW: Int?) {
        guard case .idle = phase else { return }
        phase = .countdown(session: session, remaining: seconds, preTargetW: preTargetW)
    }

    /// Abandon a countdown before it fires, returning to `idle` with the steady
    /// target untouched. No-op outside a countdown.
    public mutating func cancelCountdown() {
        guard case .countdown = phase else { return }
        phase = .idle
    }

    // MARK: Tick

    /// Advance playback by one 1 Hz tick. `elapsed` is the recorder's current
    /// second and `ftp` the rider's FTP (for the scheduler's zone→watts math).
    /// Returns the actions to apply, in order:
    ///
    /// - During a countdown: decrements it; at 0 it starts the block and returns
    ///   its first `setWatts` (so the first step applies immediately, not up to a
    ///   second later).
    /// - During a running block: asks the scheduler for the current step and
    ///   returns `setWatts` only if the target changed at a boundary; once the
    ///   block is done, returns `[recordRun, revert]` and goes `idle`.
    /// - When idle: no actions.
    public mutating func tick(elapsed: Int, ftp: Int) -> [Action] {
        switch phase {
        case .idle:
            return []

        case let .countdown(session, remaining, preTargetW):
            let next = remaining - 1
            if next <= 0 {
                // Start the block *at this instant*: the settle window is over.
                // Carry the target captured when the countdown was armed so the
                // revert on end goes to where the rider was, not the first step.
                return start(session, atElapsed: elapsed, preTargetW: preTargetW, ftp: ftp)
            }
            phase = .countdown(session: session, remaining: next, preTargetW: preTargetW)
            return []

        case let .running(session, startedAtSecond, preTargetW):
            let scheduler = IntervalScheduler(session: session, ftp: ftp)
            guard let state = scheduler.target(atSecond: elapsed - startedAtSecond) else {
                // Block finished on its own: record then revert, in that order.
                return end(session: session,
                           startedAtSecond: startedAtSecond,
                           preTargetW: preTargetW,
                           finishedAtElapsed: elapsed)
            }
            guard state.targetWatts != lastCommandedWatts else { return [] }
            lastCommandedWatts = state.targetWatts
            return [.setWatts(state.targetWatts)]
        }
    }

    /// The scheduler state for the running block at `elapsed`, or nil when no
    /// block is running (or it has just finished). The ride screen mirrors this
    /// into its HUD each tick. Pure read — does not mutate playback.
    public func currentState(elapsed: Int, ftp: Int) -> IntervalTargetState? {
        guard case let .running(session, startedAtSecond, _) = phase else { return nil }
        return IntervalScheduler(session: session, ftp: ftp)
            .target(atSecond: elapsed - startedAtSecond)
    }

    // MARK: Start / stop

    /// Start a session's block immediately, capturing the ERG target in force
    /// (`preTargetW`) so ending reverts to *that* — preserving any mid-ride
    /// `TargetAdjuster` trim — and applying the first step's watts right away.
    /// `preTargetW` is the caller's current ERG setpoint (nil coalesces to the
    /// scheduler's first-step watts only if the caller has none). Used both by
    /// the countdown reaching 0 and by any direct start.
    public mutating func start(_ session: IntervalSession,
                               atElapsed elapsed: Int,
                               preTargetW: Int?,
                               ftp: Int) -> [Action] {
        let scheduler = IntervalScheduler(session: session, ftp: ftp)
        // Capture the pre-block target so end() can restore it. Fall back to the
        // first step's watts if the caller genuinely has no ERG target yet, so
        // the revert is never to an arbitrary value.
        let firstStepWatts = scheduler.target(atSecond: 0)?.targetWatts
        let captured = preTargetW ?? firstStepWatts ?? 0
        phase = .running(session: session, startedAtSecond: elapsed, preTargetW: captured)
        lastCommandedWatts = nil

        // Apply the first step now rather than waiting a tick.
        guard let state = scheduler.target(atSecond: 0) else {
            // Degenerate session with no steps: end immediately (record nothing
            // meaningful, just revert to where we were).
            return end(session: session,
                       startedAtSecond: elapsed,
                       preTargetW: captured,
                       finishedAtElapsed: elapsed)
        }
        lastCommandedWatts = state.targetWatts
        return [.setWatts(state.targetWatts)]
    }

    /// Stop the running block early (rider tapped Stop, or the ride is ending),
    /// returning `[recordRun, revert]` and going `idle`. No-op (empty) outside a
    /// running block. `elapsed` is the recorder's current second, used to compute
    /// the run's actual length. This is the only public way to end a block; the
    /// tick ends it internally via the same `end(...)` path when the scheduler
    /// reports done, so both routes record-then-revert identically.
    public mutating func stop(atElapsed elapsed: Int) -> [Action] {
        guard case let .running(session, startedAtSecond, preTargetW) = phase else { return [] }
        return end(session: session,
                   startedAtSecond: startedAtSecond,
                   preTargetW: preTargetW,
                   finishedAtElapsed: elapsed)
    }

    // MARK: Private

    /// Common block-end path: emit the run record *then* the revert (that order
    /// is load-bearing — the summary must capture the run before the target is
    /// restored), clear per-block state, and return to `idle`.
    private mutating func end(session: IntervalSession,
                              startedAtSecond: Int,
                              preTargetW: Int,
                              finishedAtElapsed: Int) -> [Action] {
        phase = .idle
        lastCommandedWatts = nil
        let actualSeconds = max(0, finishedAtElapsed - startedAtSecond)
        return [
            .recordRun(session: session,
                       startedAtSecond: startedAtSecond,
                       actualSeconds: actualSeconds),
            .revert(toWatts: preTargetW),
        ]
    }
}
