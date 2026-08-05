import Foundation

/// What the ERG should be holding right now, partway through a running
/// interval block.
public struct IntervalTargetState: Sendable, Equatable {
    /// 0-based index into `session.steps` — the step itself, not a repeat pair.
    public let stepIndex: Int
    public let totalSteps: Int
    /// The zone this step holds, so the HUD can label it without re-deriving it
    /// from watts.
    public let zone: PowerZone
    public let secondsRemainingInStep: Int
    public let targetWatts: Int
    /// Set when the whole session is one alternating work/rest pair — the
    /// overwhelmingly common shape. Mid-set the useful question is "how many
    /// hard efforts left?", which a raw step count answers only after arithmetic
    /// the rider shouldn't have to do at threshold. nil for a genuinely
    /// free-form session, where there's no rep to count.
    public let repetition: RepeatPosition?

    /// Where the current step sits in a uniform session's repeat structure.
    public struct RepeatPosition: Sendable, Equatable {
        /// 0-based repeat, so the HUD shows `index + 1` of `total`.
        public let index: Int
        public let total: Int
        /// True on the work half of the pair (the first step of each cycle).
        public let isWork: Bool

        public init(index: Int, total: Int, isWork: Bool) {
            self.index = index
            self.total = total
            self.isWork = isWork
        }
    }

    public init(stepIndex: Int,
                totalSteps: Int,
                zone: PowerZone,
                secondsRemainingInStep: Int,
                targetWatts: Int,
                repetition: RepeatPosition?) {
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
        self.zone = zone
        self.secondsRemainingInStep = secondsRemainingInStep
        self.targetWatts = targetWatts
        self.repetition = repetition
    }
}

/// Steps an `IntervalSession` through time. Stateless and pure, like
/// `RideRecorder.elapsed()`'s underlying math — the caller tracks the block's
/// start second and asks `target(atSecond:)` with elapsed-since-start on every
/// tick; there's no mutable timer to own here.
public struct IntervalScheduler: Sendable {
    public let session: IntervalSession
    public let ftp: Int

    public init(session: IntervalSession, ftp: Int) {
        self.session = session
        self.ftp = ftp
    }

    /// The step active at `elapsed` seconds into the block, or nil once the
    /// block has finished (or never had any steps). Zero-duration steps are
    /// skipped instantly rather than stalling the scan; the editor enforces a 1s
    /// minimum in practice, so this only matters as a defensive fallback for
    /// degenerate sessions built by hand.
    public func target(atSecond elapsed: Int) -> IntervalTargetState? {
        guard elapsed >= 0 else { return nil }
        let engine = ZoneEngine(ftp: ftp)
        var cursor = 0
        for (index, step) in session.steps.enumerated() {
            let end = cursor + step.durationSeconds
            if elapsed < end {
                return IntervalTargetState(
                    stepIndex: index,
                    totalSteps: session.steps.count,
                    zone: step.zone,
                    secondsRemainingInStep: end - elapsed,
                    targetWatts: engine.steadyTarget(for: step.zone),
                    repetition: session.repeatPosition(ofStep: index))
            }
            cursor = end
        }
        return nil
    }
}
