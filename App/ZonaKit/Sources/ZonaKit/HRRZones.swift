import Foundation

/// Heart-rate training zones anchored on **Heart Rate Reserve (HRR)** — the
/// Karvonen model WHOOP uses. Parallel to `HRZone`/`HRZoneEngine` (which anchors
/// on LTHR): this is the model to use when WHOOP is the source of truth, because
/// it reconstructs WHOOP's own zone boundaries exactly.
///
/// WHOOP doesn't expose zone BPMs directly, but it derives them from two numbers
/// its API *does* give us — max HR (body measurement) and resting HR (recovery) —
/// via fixed HRR percentage bands. `bpm = restingHR + fraction·(maxHR − restingHR)`.
public enum HRRZone: Int, CaseIterable, Sendable, Identifiable {
    case z1 = 1
    case z2 = 2
    case z3 = 3
    case z4 = 4
    case z5 = 5

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .z1: return "Z1 Recovery"
        case .z2: return "Z2 Endurance"
        case .z3: return "Z3 Tempo"
        case .z4: return "Z4 Threshold"
        case .z5: return "Z5 Max"
        }
    }

    public var shortName: String { "Z\(rawValue)" }

    /// Upper bound as a fraction of HRR (WHOOP's 5-zone bands).
    public var upperFraction: Double {
        switch self {
        case .z1: return 0.60   // 40–60% HRR
        case .z2: return 0.70   // 60–70%
        case .z3: return 0.80   // 70–80%
        case .z4: return 0.90   // 80–90%
        case .z5: return 1.00   // 90–100%
        }
    }

    /// Lower bound as a fraction of HRR. WHOOP's Z1 floor is 40% HRR (not 0).
    public var lowerFraction: Double {
        switch self {
        case .z1: return 0.40
        default: return HRRZone(rawValue: rawValue - 1)!.upperFraction
        }
    }
}

/// Turns a max/resting HR pair into concrete BPM bands and classifies a live HR
/// reading, using the HRR (Karvonen) formula WHOOP uses. Mirrors
/// `HRZoneEngine`'s shape so views and summaries reuse the same patterns.
public struct HRRZoneEngine: Sendable {
    /// Maximum heart rate, in beats per minute (WHOOP body measurement).
    public let maxHR: Int
    /// Resting heart rate, in beats per minute (WHOOP recovery).
    public let restingHR: Int

    public init(maxHR: Int, restingHR: Int) {
        self.maxHR = maxHR
        self.restingHR = restingHR
    }

    /// Heart rate reserve: the span the zone fractions are taken of.
    public var reserve: Int { maxHR - restingHR }

    /// Convert an HRR fraction to an absolute BPM via Karvonen.
    private func bpm(atFraction fraction: Double) -> Int {
        Int((Double(restingHR) + fraction * Double(reserve)).rounded())
    }

    public func bpmRange(for zone: HRRZone) -> ClosedRange<Int> {
        bpm(atFraction: zone.lowerFraction)...bpm(atFraction: zone.upperFraction)
    }

    /// Which zone a live HR reading falls into (for on-screen feedback). A reading
    /// below Z1's floor still reports Z1; above Z5's ceiling reports Z5.
    public func zone(forHR bpm: Int) -> HRRZone {
        guard reserve > 0 else { return .z1 }
        let fraction = Double(bpm - restingHR) / Double(reserve)
        for z in HRRZone.allCases where fraction <= z.upperFraction {
            return z
        }
        return .z5
    }
}
