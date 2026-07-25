import Foundation

/// What the rider actually held during one step of an interval run — the
/// *achieved* counterpart to the *prescribed* target `IntervalScheduler`
/// resolved for that same step.
///
/// Every field is optional because a step's window can legitimately contain no
/// usable samples: the ride can end mid-rep, a strap can drop, and the crank
/// meter expires on a coast (see `RideMetrics.powerMeterW`). A step with no
/// readings reports nil rather than 0 — "we don't know" and "you held zero
/// watts" are different claims, and the summary renders the former as "—".
public struct IntervalStepAchievement: Sendable, Equatable, Identifiable {
    /// 0-based index into the session's `steps`, matching
    /// `IntervalTargetState.stepIndex`. A free-form session has no inherent
    /// repeat structure, so a step is identified by its position, not by a
    /// rep number and a work/rest flag.
    public let stepIndex: Int
    /// The zone this step prescribed, so the summary can label the row without
    /// re-reading the session alongside.
    public let zone: PowerZone
    /// Seconds of this step that actually elapsed. Less than the authored
    /// duration when the run was stopped (or the ride ended) partway through it;
    /// the step is still reported, over the seconds it did run.
    public let seconds: Int

    /// Trainer watts — the source of truth, and what ERG was holding, so this is
    /// what compares like-for-like against the step's target.
    public let avgPowerW: Int?
    public let maxPowerW: Int?
    /// Crank-meter (SRAM/Quarq) watts, when one was paired. A parallel channel,
    /// never merged into the trainer's: it reads a few watts high by design
    /// (direct crank torque vs. flywheel estimate + drivetrain loss).
    public let avgPowerMeterW: Int?
    /// Computed but deliberately not rendered today — the summary's table shows
    /// the meter's average only, since a fourth watt column crowds the row and
    /// the trainer's max already answers "how hard was the spike?". Kept because
    /// it's part of a complete per-step record and costs nothing to derive; it's
    /// the obvious column to add if peaks per rep ever earn their space.
    public let maxPowerMeterW: Int?
    /// Average is what the summary shows: across a set it's HR *drift* that's
    /// informative, where the per-step peak is largely noise.
    public let avgHeartRateBpm: Int?
    /// Also computed but not rendered today — same reasoning as
    /// `maxPowerMeterW`.
    public let maxHeartRateBpm: Int?

    public var id: Int { stepIndex }

    public init(stepIndex: Int,
                zone: PowerZone,
                seconds: Int,
                avgPowerW: Int?,
                maxPowerW: Int?,
                avgPowerMeterW: Int?,
                maxPowerMeterW: Int?,
                avgHeartRateBpm: Int?,
                maxHeartRateBpm: Int?) {
        self.stepIndex = stepIndex
        self.zone = zone
        self.seconds = seconds
        self.avgPowerW = avgPowerW
        self.maxPowerW = maxPowerW
        self.avgPowerMeterW = avgPowerMeterW
        self.maxPowerMeterW = maxPowerMeterW
        self.avgHeartRateBpm = avgHeartRateBpm
        self.maxHeartRateBpm = maxHeartRateBpm
    }

    /// True when no channel produced a reading for this step — the summary can
    /// skip such a row rather than printing a line of dashes.
    public var isEmpty: Bool {
        avgPowerW == nil && avgPowerMeterW == nil && avgHeartRateBpm == nil
    }
}

/// Slices a ride's samples into per-step achieved figures for an `IntervalRun`.
///
/// Pure and stateless, like `IntervalScheduler` — which is deliberate, because
/// this must carve the run's window on *exactly* the boundaries the scheduler
/// drove ERG on. It walks the same `session.steps` sequence with the same
/// running cursor, so step 5 here is the identical second-range step 5 was
/// commanded over. Deriving boundaries any other way (e.g. dividing the elapsed
/// time by the step count) would drift against a run that was stopped early, and
/// silently misattribute samples to the wrong step.
public struct IntervalAchievement: Sendable {
    /// Per-step achieved figures for `run`, in ride order (step 0, step 1, …).
    ///
    /// Steps the run never reached are omitted entirely rather than reported as
    /// empty rows: an eight-step session stopped after four returns four
    /// entries, so "what you did" doesn't pad itself out with what you didn't.
    /// A partially-ridden step *is* included, over the seconds it ran.
    ///
    /// `samples` may be the whole ride's — it's filtered to each step's window
    /// here, so callers pass `ride.samples` directly.
    public static func perStep(run: IntervalRun, samples: [RideSample]) -> [IntervalStepAchievement] {
        let steps = run.session.steps
        guard !steps.isEmpty, run.actualSeconds > 0 else { return [] }

        var result: [IntervalStepAchievement] = []
        // Cursor is seconds-since-block-start, the same axis `IntervalScheduler`
        // walks; `startedAtSecond` shifts it onto the ride's own axis to match
        // `RideSample.secondsFromStart`.
        var cursor = 0

        for (index, step) in steps.enumerated() {
            guard cursor < run.actualSeconds else { break }
            // Clamp the step to what actually ran, so an early stop reports its
            // final partial step over the seconds it lasted instead of claiming
            // the full authored duration.
            let end = min(cursor + step.durationSeconds, run.actualSeconds)
            let ranSeconds = end - cursor
            guard ranSeconds > 0 else { cursor = end; continue }

            let from = run.startedAtSecond + cursor
            let until = run.startedAtSecond + end
            // Half-open [from, until): each second belongs to exactly one step,
            // so a boundary second isn't double-counted into both the work half
            // and the rest half that follows it.
            let window = samples.filter { $0.secondsFromStart >= from && $0.secondsFromStart < until }

            result.append(IntervalStepAchievement(
                stepIndex: index,
                zone: step.zone,
                seconds: ranSeconds,
                avgPowerW: average(window.compactMap(\.powerW)),
                maxPowerW: window.compactMap(\.powerW).max(),
                avgPowerMeterW: average(window.compactMap(\.powerMeterW)),
                maxPowerMeterW: window.compactMap(\.powerMeterW).max(),
                avgHeartRateBpm: average(window.compactMap(\.heartRateBpm)),
                maxHeartRateBpm: window.compactMap(\.heartRateBpm).max()))

            cursor = end
        }
        return result
    }

    /// Mean of the readings that exist, rounded to nearest; nil for none.
    ///
    /// `compactMap` at the call sites means a channel that was quiet for part of
    /// a step averages over the seconds it *did* report — the alternative,
    /// treating a missing reading as 0, would drag a coasting rep's leg power
    /// toward zero and fabricate a number the rider never held.
    private static func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }
}
