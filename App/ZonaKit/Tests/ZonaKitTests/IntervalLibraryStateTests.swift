import Foundation
import Testing
@testable import ZonaKit

/// Mirrors `RideSettingsStateTests` in shape: pins the pure add/update/remove
/// logic that the app target's `UserDefaults`-backed wrapper will call through.
struct IntervalLibraryStateTests {

    private func session(name: String = "4x30/30 VO2") -> IntervalSession {
        IntervalSession(
            name: name,
            repeats: 4,
            work: IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
            rest: IntervalStep(durationSeconds: 30, zone: .z1Recovery))
    }

    @Test func startsEmptyByDefault() {
        #expect(IntervalLibraryState().sessions.isEmpty)
    }

    @Test func addAppendsToTheList() {
        var library = IntervalLibraryState()
        let a = session(name: "A")
        let b = session(name: "B")
        library.add(a)
        library.add(b)
        #expect(library.sessions.map(\.name) == ["A", "B"])
    }

    @Test func updateReplacesTheMatchingSessionById() {
        var library = IntervalLibraryState()
        let original = session(name: "Original")
        library.add(original)

        var edited = original
        edited.name = "Edited"
        edited.repeats = 6
        library.update(edited)

        #expect(library.sessions.count == 1)
        #expect(library.sessions[0].name == "Edited")
        #expect(library.sessions[0].repeats == 6)
    }

    @Test func updateIsANoOpForAnUnknownId() {
        var library = IntervalLibraryState()
        library.add(session(name: "Kept"))
        library.update(session(name: "Unrelated"))
        #expect(library.sessions.map(\.name) == ["Kept"])
    }

    @Test func removeDropsTheMatchingSession() {
        var library = IntervalLibraryState()
        let a = session(name: "A")
        let b = session(name: "B")
        library.add(a)
        library.add(b)
        library.remove(id: a.id)
        #expect(library.sessions.map(\.name) == ["B"])
    }

    @Test func removeIsANoOpForAnUnknownId() {
        var library = IntervalLibraryState()
        library.add(session(name: "Kept"))
        library.remove(id: UUID())
        #expect(library.sessions.map(\.name) == ["Kept"])
    }
}
