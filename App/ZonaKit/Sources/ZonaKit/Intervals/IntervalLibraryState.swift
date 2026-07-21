import Foundation

/// The rider's saved interval sessions — a small pre-authored preset library,
/// mirroring the `RideSettingsState` pattern (pure state here, a thin
/// `@Observable` `UserDefaults`-backed wrapper in the app target).
public struct IntervalLibraryState: Sendable, Equatable {
    public var sessions: [IntervalSession]

    public init(sessions: [IntervalSession] = []) {
        self.sessions = sessions
    }

    public mutating func add(_ session: IntervalSession) {
        sessions.append(session)
    }

    /// Replaces the session with the same `id`; no-op if it isn't in the library.
    public mutating func update(_ session: IntervalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
    }

    public mutating func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
    }
}
