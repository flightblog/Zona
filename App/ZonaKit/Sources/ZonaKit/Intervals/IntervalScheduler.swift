import Foundation

/// What the ERG should be holding right now, partway through a running
/// interval block.
public struct IntervalTargetState: Sendable, Equatable {
    /// 0-based index of the current repeat, out of `totalRepeats`.
    public let repeatIndex: Int
    public let totalRepeats: Int
    public let isWork: Bool
    public let secondsRemainingInStep: Int
    public let targetWatts: Int
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
    /// block has finished (or never had any steps — e.g. `repeats <= 0`).
    /// Zero-duration steps are skipped instantly rather than stalling the
    /// scan; the editor enforces a 1s minimum in practice, so this only
    /// matters as a defensive fallback for degenerate sessions built by hand.
    public func target(atSecond elapsed: Int) -> IntervalTargetState? {
        guard elapsed >= 0 else { return nil }
        let engine = ZoneEngine(ftp: ftp)
        var cursor = 0
        for (index, step) in session.steps.enumerated() {
            let end = cursor + step.durationSeconds
            if elapsed < end {
                return IntervalTargetState(
                    repeatIndex: index / 2,
                    totalRepeats: session.repeats,
                    isWork: index % 2 == 0,
                    secondsRemainingInStep: end - elapsed,
                    targetWatts: engine.steadyTarget(for: step.zone))
            }
            cursor = end
        }
        return nil
    }
}
