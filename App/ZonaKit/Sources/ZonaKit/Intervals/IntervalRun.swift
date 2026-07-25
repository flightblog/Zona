import Foundation

/// A record that an interval session actually ran during a ride: which session,
/// when it began (seconds from ride start), and how long it ran before it ended.
///
/// `actualSeconds` is what really elapsed, which is *not* always the session's
/// authored `totalDurationSeconds`: the rider can stop a block early from the
/// HUD, and a ride can end mid-block. So the summary reports both — planned
/// (from the session) and actual (from here) — and a run that fell short reads
/// as such rather than being back-filled to its plan.
///
/// `startedAtSecond` + `actualSeconds` also delimit the run's window into the
/// ride's samples (`RideRecording.samples` / `Ride.samples` share the same
/// seconds-from-start axis). `IntervalAchievement.perStep` reads exactly that
/// window to report *achieved* avg/max watts and HR per work/rest step, beside
/// the prescribed target the summary review lists — so these two fields are load-
/// bearing for more than the completed/stopped-early footer now. Changing how
/// either is recorded would misattribute samples to the wrong repeat.
public struct IntervalRun: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// The session as it was ridden, captured at run time so a later edit to (or
    /// deletion of) the library preset doesn't restate what this ride did.
    public var session: IntervalSession
    /// Seconds from ride start at which the first block began driving ERG (after
    /// the get-ready countdown).
    public var startedAtSecond: Int
    /// Seconds the run was actually active, whether it completed on its own or
    /// the rider stopped it (or ended the ride) early. Clamped to ≥ 0.
    public var actualSeconds: Int

    public init(id: UUID = UUID(), session: IntervalSession, startedAtSecond: Int, actualSeconds: Int) {
        self.id = id
        self.session = session
        self.startedAtSecond = startedAtSecond
        self.actualSeconds = max(0, actualSeconds)
    }

    /// True when the run ran for at least its full authored length — i.e. it
    /// wasn't stopped early. Uses `>=` because a run that ticks a second past the
    /// last step (before the scheduler reports done) is still "completed".
    public var completed: Bool {
        actualSeconds >= session.totalDurationSeconds
    }
}
