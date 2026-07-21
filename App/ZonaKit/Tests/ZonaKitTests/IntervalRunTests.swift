import Foundation
import Testing
@testable import ZonaKit

struct IntervalRunTests {

    private func session(repeats: Int = 4, workSeconds: Int = 30, restSeconds: Int = 30) -> IntervalSession {
        IntervalSession(
            name: "4 x 30/30",
            repeats: repeats,
            work: IntervalStep(durationSeconds: workSeconds, zone: .z5VO2Max),
            rest: IntervalStep(durationSeconds: restSeconds, zone: .z1Recovery))
    }

    /// A run that lasted at least the authored total reads as completed.
    @Test func runningTheFullLengthIsCompleted() {
        let s = session()   // 4 × (30 + 30) = 240s
        let run = IntervalRun(session: s, startedAtSecond: 100, actualSeconds: 240)
        #expect(run.completed)
    }

    /// One extra second (the tick before the scheduler reports done) still counts
    /// as completed, not "over".
    @Test func oneSecondPastTheEndIsStillCompleted() {
        let run = IntervalRun(session: session(), startedAtSecond: 0, actualSeconds: 241)
        #expect(run.completed)
    }

    /// A run stopped before its authored total is not completed — this is what the
    /// summary flags as "stopped early".
    @Test func stoppingShortIsNotCompleted() {
        let run = IntervalRun(session: session(), startedAtSecond: 0, actualSeconds: 90)
        #expect(!run.completed)
    }

    /// A negative actual (clock skew, or a run recorded before its start second)
    /// is clamped to 0 rather than stored negative.
    @Test func negativeActualIsClampedToZero() {
        let run = IntervalRun(session: session(), startedAtSecond: 50, actualSeconds: -10)
        #expect(run.actualSeconds == 0)
        #expect(!run.completed)
    }

    /// The run round-trips through Codable (it's persisted as a JSON blob on the
    /// ride), preserving the session it was ridden under.
    @Test func codableRoundTrip() throws {
        let run = IntervalRun(session: session(), startedAtSecond: 120, actualSeconds: 200)
        let data = try JSONEncoder().encode([run])
        let decoded = try JSONDecoder().decode([IntervalRun].self, from: data)
        #expect(decoded == [run])
        #expect(decoded.first?.session.name == "4 x 30/30")
    }
}
