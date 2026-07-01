import SwiftData
import SwiftUI
import ZonaKit

@main
struct ZonaApp: App {
    // One controller for the whole app session, backed by persisted sensor
    // memory so we reconnect to the exact devices last paired. HR is required
    // to ride (zones are HR-based).
    @State private var controller: TrainerController = {
        let c = TrainerController(memory: SensorMemoryStore())
        c.requiresHeartRate = true
        return c
    }()
    @State private var settings = RideSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
                .environment(settings)
        }
        // On-device store for now; the model is CloudKit-ready when we want sync.
        .modelContainer(for: [Ride.self, RideSampleModel.self])
        #if os(macOS)
        .defaultSize(width: 480, height: 640)
        #endif
    }
}

/// User-tunable ride inputs, persisted with @AppStorage-backed defaults.
@Observable
final class RideSettings {
    var ftp: Int {
        didSet { UserDefaults.standard.set(ftp, forKey: "ftp") }
    }
    var zone: PowerZone {
        didSet { UserDefaults.standard.set(zone.rawValue, forKey: "zone") }
    }
    /// Where in the zone band to hold, 0…1 (0.5 = middle).
    var bandPosition: Double {
        didSet { UserDefaults.standard.set(bandPosition, forKey: "bandPosition") }
    }

    // Heart-rate side: zones are HR-based (LTHR). The trainer still holds a
    // steady power (ERG) target; HR defines the zone the rider aims for.
    var lthr: Int {
        didSet { UserDefaults.standard.set(lthr, forKey: "lthr") }
    }
    var hrZone: HRZone {
        didSet { UserDefaults.standard.set(hrZone.rawValue, forKey: "hrZone") }
    }

    init() {
        let storedFTP = UserDefaults.standard.integer(forKey: "ftp")
        ftp = storedFTP == 0 ? 200 : storedFTP
        let storedZone = UserDefaults.standard.integer(forKey: "zone")
        zone = PowerZone(rawValue: storedZone) ?? .z2Endurance
        let storedPos = UserDefaults.standard.double(forKey: "bandPosition")
        bandPosition = storedPos == 0 ? 0.5 : storedPos
        let storedLTHR = UserDefaults.standard.integer(forKey: "lthr")
        lthr = storedLTHR == 0 ? 160 : storedLTHR
        let storedHRZone = UserDefaults.standard.integer(forKey: "hrZone")
        hrZone = HRZone(rawValue: storedHRZone) ?? .z2Endurance
    }

    var engine: ZoneEngine { ZoneEngine(ftp: ftp) }
    var target: Int { engine.steadyTarget(for: zone, position: bandPosition) }

    var hrEngine: HRZoneEngine { HRZoneEngine(lthr: lthr) }
    var targetHRBand: ClosedRange<Int> { hrEngine.bpmRange(for: hrZone) }
}
