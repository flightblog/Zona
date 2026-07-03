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

    /// Shared SwiftData store, backed by the user's private CloudKit database so
    /// rides follow them across iPhone/iPad/Mac. The model was built
    /// CloudKit-ready (all defaults, no `.unique`, optional relationships), so no
    /// migration is needed. Requires the iCloud (CloudKit) + Push Notifications
    /// capabilities on the App ID and the matching entitlements — see
    /// Zona.macOS.entitlements.
    private let modelContainer: ModelContainer = {
        let schema = Schema([Ride.self, RideSampleModel.self])

        // Point the store at an explicit URL in Application Support, and make sure
        // that directory EXISTS before opening. On a freshly installed app,
        // `Application Support` isn't created yet; if SwiftData tries to create
        // `default.store` there first, the create fails (the sandbox denies
        // writing a file into a missing parent) and Core Data falls into a
        // synchronous recovery path that creates the directory and retries — a
        // recovery that blocked the main thread for ~30 s on first launch,
        // freezing the setup screen until it finished. Creating the directory up
        // front skips the failed attempt and its slow recovery entirely.
        //
        // (The previous `.modelContainer(for:)` created its own location for us;
        // moving to an explicit CloudKit configuration made the directory ours to
        // guarantee. Keep SwiftData's default `default.store` filename so a store
        // already written at this location is reused, not orphaned.)
        let appSupport = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true)
        let storeURL = appSupport.appending(path: "default.store")

        let config = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .private("iCloud.org.flightblog.zona"))
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
                .environment(settings)
        }
        .modelContainer(modelContainer)
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

    /// When true, the ride screen closes the loop: it nudges the ERG watt target
    /// to hold HR in `hrZone`. Default false — the app stays open-loop unless the
    /// rider opts in. See `HRHoldController`.
    var hrHoldEnabled: Bool {
        didSet { UserDefaults.standard.set(hrHoldEnabled, forKey: "hrHoldEnabled") }
    }

    /// Light/dark appearance. `.system` follows the OS setting; the others force
    /// the app one way regardless. Applied via `.preferredColorScheme` at the
    /// root of the view tree.
    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
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
        hrHoldEnabled = UserDefaults.standard.bool(forKey: "hrHoldEnabled")  // default false
        let storedAppearance = UserDefaults.standard.integer(forKey: "appearance")
        appearance = Appearance(rawValue: storedAppearance) ?? .system  // default .system
    }

    var engine: ZoneEngine { ZoneEngine(ftp: ftp) }
    var target: Int { engine.steadyTarget(for: zone, position: bandPosition) }

    var hrEngine: HRZoneEngine { HRZoneEngine(lthr: lthr) }
    var targetHRBand: ClosedRange<Int> { hrEngine.bpmRange(for: hrZone) }
}

/// App appearance choice. Raw values are persisted, so keep them stable.
enum Appearance: Int, CaseIterable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// The scheme to force, or `nil` for `.system` (follow the OS).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
