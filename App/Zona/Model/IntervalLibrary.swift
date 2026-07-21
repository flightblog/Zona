import Foundation
import ZonaKit

/// The rider's saved interval sessions, persisted to `UserDefaults`.
///
/// A thin `@Observable` wrapper over `ZonaKit`'s pure `IntervalLibraryState`,
/// same split as `RideSettings` over `RideSettingsState`: this layer only loads
/// the sessions on launch and JSON-encodes them back whenever they change.
@Observable
final class IntervalLibrary {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let key = "intervalLibrarySessions"

    private var state: IntervalLibraryState {
        didSet { persist() }
    }

    var sessions: [IntervalSession] { state.sessions }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.state = IntervalLibrary.load(from: defaults)
    }

    func add(_ session: IntervalSession) { state.add(session) }
    func update(_ session: IntervalSession) { state.update(session) }
    func remove(id: UUID) { state.remove(id: id) }

    // MARK: UserDefaults glue

    private static func load(from defaults: UserDefaults) -> IntervalLibraryState {
        guard let data = defaults.data(forKey: key),
              let sessions = try? JSONDecoder().decode([IntervalSession].self, from: data)
        else { return IntervalLibraryState() }
        return IntervalLibraryState(sessions: sessions)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state.sessions) else { return }
        defaults.set(data, forKey: IntervalLibrary.key)
    }
}
