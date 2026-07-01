import Foundation
import ZonaKit

/// UserDefaults-backed implementation of ZonaKit's `SensorMemory`, so the app
/// reconnects to the exact devices you last paired (per sensor kind) instead of
/// grabbing whatever's nearby.
struct SensorMemoryStore: SensorMemory {
    // UserDefaults is documented thread-safe but not marked Sendable; the hub
    // may read/write this from its BLE queue. `nonisolated(unsafe)` is sound here.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(for kind: SensorKind) -> String {
        "sensor.remembered.\(kind.rawValue)"
    }

    func rememberedIdentifier(for kind: SensorKind) -> UUID? {
        guard let s = defaults.string(forKey: key(for: kind)) else { return nil }
        return UUID(uuidString: s)
    }

    func remember(_ identifier: UUID, for kind: SensorKind) {
        defaults.set(identifier.uuidString, forKey: key(for: kind))
    }
}
