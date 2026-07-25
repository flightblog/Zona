import Foundation

/// App appearance choice. Raw values are persisted, so keep them stable. The
/// SwiftUI-facing `colorScheme` mapping lives in an app-target extension — this
/// enum stays pure so `RideSettingsState` (and its tests) don't pull in SwiftUI.
public enum Appearance: Int, CaseIterable, Sendable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// User-tunable ride inputs as a pure value — the state half of `RideSettings`.
///
/// All of Zona's settings *decision logic* lives here (zone-sync, WHOOP-vs-LTHR
/// zoning resolution, the target HR band, the WHOOP-inputs-as-optionals view),
/// so it's unit-testable in `ZonaKit` without running the app. The app target's
/// `RideSettings` is a thin `@Observable` wrapper that owns one of these and
/// persists it to `UserDefaults` — the same shape as `TrainerController`
/// wrapping `SensorHub`, but without a protocol seam: `UserDefaults` is directly
/// testable, so unlike `SensorMemory`/`TokenStore` it needs no fake.
///
/// WHOOP's max/resting HR are stored as optionals here (nil = "not fetched");
/// the app's `UserDefaults` glue is what maps them to/from the 0-means-unset
/// integer columns on disk.
public struct RideSettingsState: Sendable, Equatable {
    /// Functional Threshold Power, the basis for every power-zone watt target.
    public var ftp: Int
    /// The single zone the rider picks; the target HR zone mirrors it.
    public var zone: PowerZone
    /// Where in the zone band to hold, 0…1 (0.5 = middle).
    public var bandPosition: Double
    /// Lactate threshold HR — the anchor for the manual (Friel) HR bands.
    public var lthr: Int
    /// The target HR zone. Not picked independently — kept in lockstep with
    /// `zone` via `syncHRZoneToHoldZone()`. Stored so `targetHRBand`, ride
    /// records, and summaries can read it directly.
    public var hrZone: HRZone
    /// Max HR fetched from WHOOP, or nil if never fetched.
    public var whoopMaxHR: Int?
    /// Resting HR fetched from WHOOP, or nil if never fetched.
    public var whoopRestingHR: Int?
    /// Rider body weight, manually entered — the fallback used whenever
    /// `whoopWeightKg` hasn't been fetched.
    public var weightKg: Double
    /// Body weight fetched from WHOOP's body-measurement endpoint, or nil if never
    /// fetched. Takes priority over `weightKg` (see `effectiveWeightKg`), the same
    /// "holding the number is the decision to use it" shape as `whoopMaxHR`.
    public var whoopWeightKg: Double?
    /// Light/dark appearance.
    public var appearance: Appearance

    /// The app's launch defaults, matching the pre-refactor `init()` fallbacks.
    public init(
        ftp: Int = 200,
        zone: PowerZone = .z2Endurance,
        bandPosition: Double = 0.5,
        lthr: Int = 160,
        hrZone: HRZone = .z2Endurance,
        whoopMaxHR: Int? = nil,
        whoopRestingHR: Int? = nil,
        weightKg: Double = 75,
        whoopWeightKg: Double? = nil,
        appearance: Appearance = .system
    ) {
        self.ftp = ftp
        self.zone = zone
        self.bandPosition = bandPosition
        self.lthr = lthr
        self.hrZone = hrZone
        self.whoopMaxHR = whoopMaxHR
        self.whoopRestingHR = whoopRestingHR
        self.weightKg = weightKg
        self.whoopWeightKg = whoopWeightKg
        self.appearance = appearance
    }

    // MARK: Zone sync

    /// Point the target HR zone at the selected Hold zone. `PowerZone` and
    /// `HRZone` share raw values 1–5 for the same zones, so the mapping is by
    /// raw value; if the power zone has no HR counterpart (Z6/Z7 have none) the
    /// HR zone is left unchanged — can't happen for the Z1/Z2 the picker offers,
    /// but pinned as an invariant so a future picker can't silently desync it.
    public mutating func syncHRZoneToHoldZone() {
        guard let matched = HRZone(rawValue: zone.rawValue), matched != hrZone else { return }
        hrZone = matched
    }

    // MARK: Power target

    public var engine: ZoneEngine { ZoneEngine(ftp: ftp) }
    public var target: Int { engine.steadyTarget(for: zone, position: bandPosition) }

    // MARK: HR zones (LTHR fallback vs WHOOP source-of-truth)

    /// The HRR (WHOOP) zone engine, non-nil only once both inputs are present.
    /// Only for *listing* all five WHOOP bands on the setup screen — scoring goes
    /// through `zoning`, which is the one place that decides which model applies.
    public var hrrEngine: HRRZoneEngine? {
        guard let maxHR = whoopMaxHR, let restingHR = whoopRestingHR, maxHR > restingHR else {
            return nil
        }
        return HRRZoneEngine(maxHR: maxHR, restingHR: restingHR)
    }

    /// The HR-zone model a ride started right now would be scored against: WHOOP's
    /// HRR bands whenever both WHOOP inputs are on hand, else the manual LTHR
    /// bands. Holding WHOOP's numbers *is* the decision to use them — so LTHR is
    /// what you ride to only until WHOOP is connected, and disconnecting (which
    /// clears them) is what reverts you. Mirrors `Ride.zoning`.
    public var zoning: RideHRZoning {
        RideHRZoning.resolve(maxHR: whoopMaxHR, restingHR: whoopRestingHR, lthr: lthr)
    }

    /// The target HR band for the selected zone, under whichever model is active.
    public var targetHRBand: ClosedRange<Int> { zoning.bpmRange(for: hrZone) }

    // MARK: WHOOP inputs

    /// Store the two inputs WHOOP derives its zones from. Called on every WHOOP
    /// fetch (connect, Refresh, pre-ride sync), each of which equally puts the
    /// rider on WHOOP's zones, since holding the numbers is what makes them the
    /// model.
    public mutating func storeWhoopInputs(maxHR: Int, restingHR: Int) {
        whoopMaxHR = maxHR
        whoopRestingHR = restingHR
    }

    /// Store body weight fetched from WHOOP. Called alongside `storeWhoopInputs`
    /// on every WHOOP fetch, when WHOOP's body-measurement response includes one
    /// (it's optional on WHOOP's side too).
    public mutating func storeWhoopWeight(_ kg: Double) {
        whoopWeightKg = kg
    }

    /// Forget everything WHOOP told us and revert to manual inputs ("Disconnect"):
    /// LTHR zones instead of WHOOP's HRR bands, and the manually-entered weight
    /// instead of WHOOP's body measurement.
    public mutating func clearWhoopZones() {
        whoopMaxHR = nil
        whoopRestingHR = nil
        whoopWeightKg = nil
    }

    // MARK: Weight

    /// The weight actually used for watts-per-kilogram: WHOOP's body measurement
    /// when available, else the manually entered value.
    public var effectiveWeightKg: Double { whoopWeightKg ?? weightKg }
}
