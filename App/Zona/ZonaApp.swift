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
    @State private var intervalLibrary = IntervalLibrary()

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
                .environment(intervalLibrary)
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .defaultSize(width: 480, height: 640)
        #endif
    }
}

/// User-tunable ride inputs, persisted to `UserDefaults`.
///
/// A thin `@Observable` wrapper over `ZonaKit`'s pure `RideSettingsState`, which
/// holds all the decision logic (zone-sync, WHOOP-vs-LTHR zoning, target band)
/// and is unit-tested there. This layer only loads the state on launch and
/// writes it back whenever it changes — the same split as `TrainerController`
/// over `SensorHub`, but without a protocol seam: `UserDefaults` is directly
/// testable, so unlike `SensorMemory`/`TokenStore` it needs no fake.
///
/// The `UserDefaults` keys are load-bearing — existing installs read their
/// settings from these exact strings, so renaming any wipes them. WHOOP's
/// max/resting HR persist as 0-means-unset integers, mapped to/from the state's
/// optionals here (the one bit of decoding this glue owns).
@Observable
final class RideSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// The pure state. Mutating any exposed field goes through `state`, then
    /// `persist()` writes the whole thing back — cheap for eight `UserDefaults`
    /// keys, and it means there's exactly one place to keep read and write in
    /// sync (`load`/`persist`) instead of eight parallel `didSet`s.
    private var state: RideSettingsState {
        didSet { persist() }
    }

    var ftp: Int {
        get { state.ftp }
        set { state.ftp = newValue }
    }
    var zone: PowerZone {
        get { state.zone }
        // The Hold zone is the single zone the rider picks; the target HR zone
        // tracks it 1:1 (both share raw values 1–5) so the Ride View's BPM gauge
        // reflects the selected zone rather than a stale independent default.
        set { state.zone = newValue; state.syncHRZoneToHoldZone() }
    }
    var bandPosition: Double {
        get { state.bandPosition }
        set { state.bandPosition = newValue }
    }
    var lthr: Int {
        get { state.lthr }
        set { state.lthr = newValue }
    }
    var hrZone: HRZone {
        get { state.hrZone }
        set { state.hrZone = newValue }
    }
    var weightKg: Double {
        get { state.weightKg }
        set { state.weightKg = newValue }
    }
    var appearance: Appearance {
        get { state.appearance }
        set { state.appearance = newValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.state = RideSettings.load(from: defaults)
        // The Hold zone is the source of truth; realign the target HR zone to it
        // in case a stored value diverged (e.g. from the old separate HR-zone
        // picker). This runs before the first `persist()`, so it doesn't churn.
        state.syncHRZoneToHoldZone()
    }

    // MARK: Read-through logic (all lives on RideSettingsState)

    var engine: ZoneEngine { state.engine }
    var target: Int { state.target }
    var whoopMaxHR: Int? { state.whoopMaxHR }
    var whoopRestingHR: Int? { state.whoopRestingHR }
    var whoopWeightKg: Double? { state.whoopWeightKg }
    /// The weight actually used for watts-per-kilogram: WHOOP's body measurement
    /// when available, else the manually entered `weightKg`.
    var effectiveWeightKg: Double { state.effectiveWeightKg }
    var hrrEngine: HRRZoneEngine? { state.hrrEngine }
    /// The HR-zone model a ride started right now would be scored against. Handed
    /// to `Ride.make` at ride start and asked by the setup screen. Mirrors
    /// `Ride.zoning`.
    var zoning: RideHRZoning { state.zoning }
    var targetHRBand: ClosedRange<Int> { state.targetHRBand }

    func storeWhoopInputs(maxHR: Int, restingHR: Int) {
        state.storeWhoopInputs(maxHR: maxHR, restingHR: restingHR)
    }

    func storeWhoopWeight(_ kg: Double) { state.storeWhoopWeight(kg) }

    func clearWhoopZones() { state.clearWhoopZones() }

    // MARK: UserDefaults glue

    /// Read a `RideSettingsState` from `defaults`, applying the launch defaults
    /// for any unset key (a still-zero integer). The 0-means-unset mapping for
    /// the WHOOP inputs lives here, keeping `RideSettingsState` free of the
    /// sentinel.
    private static func load(from defaults: UserDefaults) -> RideSettingsState {
        let storedFTP = defaults.integer(forKey: "ftp")
        let storedPos = defaults.double(forKey: "bandPosition")
        let storedLTHR = defaults.integer(forKey: "lthr")
        let storedMax = defaults.integer(forKey: "whoopMaxHR")            // 0 = unset
        let storedResting = defaults.integer(forKey: "whoopRestingHR")    // 0 = unset
        let storedWeight = defaults.double(forKey: "weightKg")
        let storedWhoopWeight = defaults.double(forKey: "whoopWeightKg")  // 0 = unset
        return RideSettingsState(
            ftp: storedFTP == 0 ? 200 : storedFTP,
            zone: PowerZone(rawValue: defaults.integer(forKey: "zone")) ?? .z2Endurance,
            bandPosition: storedPos == 0 ? 0.5 : storedPos,
            lthr: storedLTHR == 0 ? 160 : storedLTHR,
            hrZone: HRZone(rawValue: defaults.integer(forKey: "hrZone")) ?? .z2Endurance,
            whoopMaxHR: storedMax > 0 ? storedMax : nil,
            whoopRestingHR: storedResting > 0 ? storedResting : nil,
            weightKg: storedWeight == 0 ? 75 : storedWeight,
            whoopWeightKg: storedWhoopWeight > 0 ? storedWhoopWeight : nil,
            appearance: Appearance(rawValue: defaults.integer(forKey: "appearance")) ?? .system)
    }

    /// Write the whole state back under the load-bearing keys. WHOOP's optionals
    /// map back to 0-means-unset integers (or doubles, for weight).
    private func persist() {
        defaults.set(state.ftp, forKey: "ftp")
        defaults.set(state.zone.rawValue, forKey: "zone")
        defaults.set(state.bandPosition, forKey: "bandPosition")
        defaults.set(state.lthr, forKey: "lthr")
        defaults.set(state.hrZone.rawValue, forKey: "hrZone")
        defaults.set(state.whoopMaxHR ?? 0, forKey: "whoopMaxHR")
        defaults.set(state.whoopRestingHR ?? 0, forKey: "whoopRestingHR")
        defaults.set(state.weightKg, forKey: "weightKg")
        defaults.set(state.whoopWeightKg ?? 0, forKey: "whoopWeightKg")
        defaults.set(state.appearance.rawValue, forKey: "appearance")
    }
}

extension Appearance {
    /// The scheme to force, or `nil` for `.system` (follow the OS). Lives in the
    /// app target because `ColorScheme` is SwiftUI; the enum itself is in ZonaKit.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
