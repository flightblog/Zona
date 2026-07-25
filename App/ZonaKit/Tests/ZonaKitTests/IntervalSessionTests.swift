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

    // MARK: The uniform convenience init still flattens to alternating pairs

    @Test func repeatsInitFlattensToAlternatingWorkRestPairs() {
        let steps = session().steps
        #expect(steps.count == 8)
        #expect(steps.map(\.zone) == [.z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery,
                                       .z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery])
    }

    @Test func repeatsInitYieldsNoStepsForNonPositiveRepeats() {
        let work = IntervalStep(durationSeconds: 30, zone: .z5VO2Max)
        let rest = IntervalStep(durationSeconds: 30, zone: .z1Recovery)
        #expect(IntervalSession(name: "x", repeats: 0, work: work, rest: rest).steps.isEmpty)
        #expect(IntervalSession(name: "x", repeats: -3, work: work, rest: rest).steps.isEmpty)
    }

    /// Each flattened copy is its own row in the editor's list, so repeated
    /// steps must not share an id even though they compare equal by content.
    @Test func flattenedRepeatsGetDistinctIdentities() {
        let steps = session().steps
        #expect(Set(steps.map(\.id)).count == 8)
        #expect(steps[0] == steps[2])   // equal by content
    }

    // MARK: Free-form step lists

    @Test func freeFormSessionKeepsItsStepsInOrder() {
        let s = IntervalSession(name: "Pyramid", steps: [
            IntervalStep(durationSeconds: 300, zone: .z2Endurance),
            IntervalStep(durationSeconds: 60, zone: .z4Threshold),
            IntervalStep(durationSeconds: 120, zone: .z5VO2Max),
            IntervalStep(durationSeconds: 60, zone: .z4Threshold),
        ])
        #expect(s.steps.map(\.zone) == [.z2Endurance, .z4Threshold, .z5VO2Max, .z4Threshold])
        #expect(s.totalDurationSeconds == 540)
    }

    @Test func totalDurationSecondsSumsAllSteps() {
        #expect(session().totalDurationSeconds == 4 * (30 + 30))
    }

    @Test func totalDurationIgnoresNegativeDurations() {
        let s = IntervalSession(name: "x", steps: [
            IntervalStep(durationSeconds: 60, zone: .z2Endurance),
            IntervalStep(durationSeconds: -30, zone: .z2Endurance),
        ])
        #expect(s.totalDurationSeconds == 60)
    }

    // MARK: Summary

    @Test func summaryCollapsesAUniformSessionToRepeatNotation() {
        #expect(session().summary == "4 × (30s Z5 / 30s Z1)")
    }

    @Test func summaryListsPhasesOfAFreeFormSession() {
        let s = IntervalSession(name: "Pyramid", steps: [
            IntervalStep(durationSeconds: 300, zone: .z2Endurance),
            IntervalStep(durationSeconds: 60, zone: .z4Threshold),
            IntervalStep(durationSeconds: 120, zone: .z5VO2Max),
        ])
        #expect(s.summary == "300s Z2 / 60s Z4 / 120s Z5")
    }

    /// The canonical free-form shape, and the one the whole-session-only
    /// collapser used to render worst — it spelled out every step.
    @Test func summaryCollapsesASetSurroundedByWarmupAndCooldown() {
        var steps = [IntervalStep(durationSeconds: 300, zone: .z2Endurance)]
        steps += (0..<4).flatMap { _ in
            [IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
             IntervalStep(durationSeconds: 30, zone: .z1Recovery)]
        }
        steps.append(IntervalStep(durationSeconds: 600, zone: .z2Endurance))

        #expect(IntervalSession(name: "x", steps: steps).summary
                == "300s Z2 / 4 × (30s Z5 / 30s Z1) / 600s Z2")
    }

    @Test func summaryCollapsesASetFollowedByACooldownOnly() {
        var steps = (0..<2).flatMap { _ in
            [IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
             IntervalStep(durationSeconds: 30, zone: .z1Recovery)]
        }
        steps.append(IntervalStep(durationSeconds: 600, zone: .z2Endurance))

        #expect(IntervalSession(name: "x", steps: steps).summary
                == "2 × (30s Z5 / 30s Z1) / 600s Z2")
    }

    /// A pair occurring only once reads better spelled out than as "1 × (…)".
    @Test func summaryDoesNotCollapseANonRepeatingPair() {
        let s = IntervalSession(name: "x", steps: [
            IntervalStep(durationSeconds: 300, zone: .z2Endurance),
            IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
            IntervalStep(durationSeconds: 30, zone: .z1Recovery),
            IntervalStep(durationSeconds: 600, zone: .z3Tempo),
        ])
        #expect(s.summary == "300s Z2 / 30s Z5 / 30s Z1 / 600s Z3")
    }

    @Test func summaryCollapsesConsecutiveIdenticalSteps() {
        let s = IntervalSession(name: "x", steps: [
            IntervalStep(durationSeconds: 300, zone: .z2Endurance),
            IntervalStep(durationSeconds: 60, zone: .z4Threshold),
            IntervalStep(durationSeconds: 60, zone: .z4Threshold),
            IntervalStep(durationSeconds: 60, zone: .z4Threshold),
        ])
        #expect(s.summary == "300s Z2 / 3 × 60s Z4")
    }

    @Test func summaryHandlesAnEmptySession() {
        #expect(IntervalSession(name: "x", steps: []).summary == "No steps")
    }

    /// A two-step session isn't "1 × (work / rest)" — that reads worse than just
    /// naming both steps.
    @Test func summaryDoesNotUseRepeatNotationForASinglePair() {
        let s = IntervalSession(name: "x", steps: [
            IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
            IntervalStep(durationSeconds: 30, zone: .z1Recovery),
        ])
        #expect(s.summary == "30s Z5 / 30s Z1")
    }

    // MARK: Codable

    @Test func sessionRoundTripsThroughJSON() throws {
        let original = session()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IntervalSession.self, from: data)
        #expect(decoded == original)
    }

    @Test func freeFormSessionRoundTripsThroughJSON() throws {
        let original = IntervalSession(name: "Pyramid", steps: [
            IntervalStep(durationSeconds: 300, zone: .z2Endurance),
            IntervalStep(durationSeconds: 120, zone: .z5VO2Max),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IntervalSession.self, from: data)
        #expect(decoded == original)
        #expect(decoded.steps.map(\.zone) == [.z2Endurance, .z5VO2Max])
    }

    // MARK: Legacy decoding
    //
    // Sessions are embedded in `IntervalRun` on every finished `Ride`, and
    // `Ride.intervalRuns` swallows a decode failure as []. If these break, past
    // rides silently lose their interval review — no error, just an empty card.

    /// The exact shape the pre-step-list model encoded.
    private let legacyJSON = """
    {
      "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
      "name": "4x30/30 VO2",
      "repeats": 4,
      "work": { "durationSeconds": 30, "zone": 5 },
      "rest": { "durationSeconds": 30, "zone": 1 }
    }
    """

    @Test func decodesALegacyRepeatsWorkRestBlobIntoSteps() throws {
        let decoded = try JSONDecoder().decode(IntervalSession.self,
                                               from: Data(legacyJSON.utf8))
        #expect(decoded.name == "4x30/30 VO2")
        #expect(decoded.steps.count == 8)
        #expect(decoded.steps.map(\.zone) == [.z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery,
                                              .z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery])
        #expect(decoded.steps.allSatisfy { $0.durationSeconds == 30 })
        #expect(decoded.totalDurationSeconds == 240)
    }

    /// A legacy blob must produce exactly what the old flattening did, so an
    /// old ride's achieved table slices on identical boundaries.
    @Test func legacyBlobMatchesTheEquivalentModernSession() throws {
        let decoded = try JSONDecoder().decode(IntervalSession.self,
                                               from: Data(legacyJSON.utf8))
        #expect(decoded.steps == session().steps)
    }

    @Test func preservesTheLegacyIdSoLibraryEditsStillMatch() throws {
        let decoded = try JSONDecoder().decode(IntervalSession.self,
                                               from: Data(legacyJSON.utf8))
        #expect(decoded.id == UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"))
    }

    @Test func reEncodingALegacyBlobMigratesItForward() throws {
        let decoded = try JSONDecoder().decode(IntervalSession.self,
                                               from: Data(legacyJSON.utf8))
        let reEncoded = try JSONEncoder().encode(decoded)
        let json = String(decoding: reEncoded, as: UTF8.self)
        #expect(json.contains("steps"))
        #expect(!json.contains("repeats"))
        // And it still round-trips to the same thing.
        #expect(try JSONDecoder().decode(IntervalSession.self, from: reEncoded).steps
                == decoded.steps)
    }

    @Test func legacyBlobWithZeroRepeatsDecodesToNoSteps() throws {
        let json = """
        { "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427", "name": "x", "repeats": 0,
          "work": { "durationSeconds": 30, "zone": 5 },
          "rest": { "durationSeconds": 30, "zone": 1 } }
        """
        let decoded = try JSONDecoder().decode(IntervalSession.self, from: Data(json.utf8))
        #expect(decoded.steps.isEmpty)
    }

    /// A blob with neither shape must THROW, not decode to an empty session.
    /// `Ride.intervalRuns` uses `try?`, so throwing hides the card; yielding an
    /// empty session would instead render one titled "Intervals" reading
    /// "No steps · Stopped early · 0:00 of 0:00" — fabricated history.
    @Test func blobWithNeitherShapeThrows() {
        let json = #"{ "name": "x" }"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IntervalSession.self, from: Data(json.utf8))
        }
    }

    /// The whole point of throwing: an unreadable run drops out of the ride's
    /// review rather than appearing as a real-looking empty session.
    @Test func anUnreadableRunIsDroppedFromADecodedList() throws {
        let json = """
        [{ "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
           "session": { "name": "broken" },
           "startedAtSecond": 0, "actualSeconds": 60 }]
        """
        let runs = (try? JSONDecoder().decode([IntervalRun].self, from: Data(json.utf8))) ?? []
        #expect(runs.isEmpty)
    }

    /// A run persisted under the old model must still slice into per-step
    /// achievements on the same boundaries it was ridden on.
    @Test func legacyRunStillSlicesIntoAchievements() throws {
        let session = try JSONDecoder().decode(IntervalSession.self,
                                               from: Data(legacyJSON.utf8))
        let run = IntervalRun(session: session, startedAtSecond: 0, actualSeconds: 240)
        let got = IntervalAchievement.perStep(run: run, samples: [])
        #expect(got.count == 8)
        #expect(got.map(\.seconds) == Array(repeating: 30, count: 8))
        #expect(got.map(\.zone) == [.z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery,
                                    .z5VO2Max, .z1Recovery, .z5VO2Max, .z1Recovery])
    }
}
