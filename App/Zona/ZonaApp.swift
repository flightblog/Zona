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
        didSet {
            UserDefaults.standard.set(zone.rawValue, forKey: "zone")
            // The Hold zone is the single zone the rider picks; the target HR zone
            // tracks it 1:1 (both share raw values 1–5) so the Ride View's BPM
            // gauge reflects the zone that was selected rather than a stale
            // independent default.
            syncHRZoneToHoldZone()
        }
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
    /// The target HR zone. Not picked independently — it mirrors `zone` (the Hold
    /// zone) via `syncHRZoneToHoldZone()`. Still stored so `targetHRBand`, ride
    /// records, and summaries can read it directly.
    var hrZone: HRZone {
        didSet { UserDefaults.standard.set(hrZone.rawValue, forKey: "hrZone") }
    }

    // WHOOP source-of-truth zones. WHOOP defines HR zones from max HR + resting
    // HR via Heart Rate Reserve; when connected we store those two numbers and
    // (optionally) use the resulting HRR bands instead of the manual LTHR bands.
    // 0 means "not fetched" (see `whoopMaxHR`/`whoopRestingHR` accessors below).
    private var whoopMaxHRRaw: Int {
        didSet { UserDefaults.standard.set(whoopMaxHRRaw, forKey: "whoopMaxHR") }
    }
    private var whoopRestingHRRaw: Int {
        didSet { UserDefaults.standard.set(whoopRestingHRRaw, forKey: "whoopRestingHR") }
    }
    /// When true (and WHOOP inputs are present), the ride target uses WHOOP's HRR
    /// zones; otherwise it uses the manual LTHR zones. Default false.
    var useWhoopZones: Bool {
        didSet { UserDefaults.standard.set(useWhoopZones, forKey: "useWhoopZones") }
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
        whoopMaxHRRaw = UserDefaults.standard.integer(forKey: "whoopMaxHR")        // 0 = unset
        whoopRestingHRRaw = UserDefaults.standard.integer(forKey: "whoopRestingHR") // 0 = unset
        useWhoopZones = UserDefaults.standard.bool(forKey: "useWhoopZones")  // default false
        let storedAppearance = UserDefaults.standard.integer(forKey: "appearance")
        appearance = Appearance(rawValue: storedAppearance) ?? .system  // default .system
        // The Hold zone is the source of truth; realign the target HR zone to it
        // in case a previously stored value diverged (e.g. from the old separate
        // HR-zone picker). `didSet` doesn't fire during init, so do it explicitly.
        syncHRZoneToHoldZone()
    }

    /// Point the target HR zone at the selected Hold zone. `PowerZone` and
    /// `HRZone` share raw values 1–5 for the same zones, so the mapping is by
    /// raw value; if the power zone has no HR counterpart the HR zone is left
    /// unchanged (can't happen for the Z1/Z2 the picker offers).
    private func syncHRZoneToHoldZone() {
        guard let matched = HRZone(rawValue: zone.rawValue), matched != hrZone else { return }
        hrZone = matched
    }

    var engine: ZoneEngine { ZoneEngine(ftp: ftp) }
    var target: Int { engine.steadyTarget(for: zone, position: bandPosition) }

    // MARK: HR zones (LTHR fallback vs WHOOP source-of-truth)

    /// Max HR fetched from WHOOP, or nil if never fetched.
    var whoopMaxHR: Int? { whoopMaxHRRaw > 0 ? whoopMaxHRRaw : nil }
    /// Resting HR fetched from WHOOP, or nil if never fetched.
    var whoopRestingHR: Int? { whoopRestingHRRaw > 0 ? whoopRestingHRRaw : nil }

    /// The HRR (WHOOP) zone engine, non-nil only once both inputs are present.
    var hrrEngine: HRRZoneEngine? {
        guard let maxHR = whoopMaxHR, let restingHR = whoopRestingHR, maxHR > restingHR else {
            return nil
        }
        return HRRZoneEngine(maxHR: maxHR, restingHR: restingHR)
    }

    /// True when the ride target is driven by WHOOP's zones right now (opted in
    /// *and* inputs available). Drives the SetupView labelling and the LTHR
    /// stepper's read-only state.
    var usingWhoopZones: Bool { useWhoopZones && hrrEngine != nil }

    var hrEngine: HRZoneEngine { HRZoneEngine(lthr: lthr) }

    /// The HR-zone model a ride started right now would be scored against:
    /// WHOOP's HRR bands when opted in with both inputs available, else the manual
    /// LTHR bands. Handed to `Ride.make` at save time so the finished ride carries
    /// (and keeps) the model it was actually ridden against.
    var zoning: RideHRZoning {
        guard useWhoopZones else { return .lthr(lthr) }
        return RideHRZoning.resolve(maxHR: whoopMaxHR, restingHR: whoopRestingHR, lthr: lthr)
    }

    /// The target HR band for the selected zone, under whichever model is active.
    /// `hrZone`'s raw value (1–5) maps 1:1 onto `HRRZone`, so the same picker
    /// selection carries across both models.
    var targetHRBand: ClosedRange<Int> { zoning.bpmRange(for: hrZone) }

    /// Store the two inputs WHOOP derives its zones from and switch the app onto
    /// them. Called by `WhoopModel` after a successful fetch.
    func applyWhoopZones(maxHR: Int, restingHR: Int) {
        whoopMaxHRRaw = maxHR
        whoopRestingHRRaw = restingHR
        useWhoopZones = true
    }

    /// Forget the WHOOP inputs and revert to manual LTHR zones ("Disconnect").
    func clearWhoopZones() {
        whoopMaxHRRaw = 0
        whoopRestingHRRaw = 0
        useWhoopZones = false
    }
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
