import Foundation
import Testing
@testable import ZonaKit

struct IntervalSessionTests {

    private func session() -> IntervalSession {
        IntervalSession(
            name: "4x30/30 VO2",
            repeats: 4,
            work: IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
            rest: IntervalStep(durationSeconds: 30, zone: .z1Recovery))
    }

    @Test func stepsFlattensToAlternatingWorkRestPairs() {
        let steps = session().steps
        #expect(steps.count == 8)
        #expect(steps.map(\.zone) == [.z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery,
                                       .z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery])
    }

    @Test func stepsIsEmptyForNonPositiveRepeats() {
        var s = session()
        s.repeats = 0
        #expect(s.steps.isEmpty)
        s.repeats = -3
        #expect(s.steps.isEmpty)
    }

    @Test func totalDurationSecondsSumsAllSteps() {
        #expect(session().totalDurationSeconds == 4 * (30 + 30))
    }

    @Test func summaryDescribesTheBlock() {
        #expect(session().summary == "4 x (30s Z5 / 30s Z1)")
    }

    // MARK: Codable (PowerZone needs to round-trip inside these structs)

    @Test func sessionRoundTripsThroughJSON() throws {
        let original = session()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IntervalSession.self, from: data)
        #expect(decoded == original)
    }
}
