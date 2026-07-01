import Foundation

/// Heart-rate training zones anchored on **LTHR** (lactate threshold heart
/// rate), the Friel 5-zone model. Parallel to `PowerZone`/`ZoneEngine`: power
/// zones drive the ERG *watt* setpoint the trainer holds; HR zones define and
/// display the *target* the rider is trying to land their heart rate in.
public enum HRZone: Int, CaseIterable, Sendable, Identifiable {
    case z1Recovery = 1
    case z2Endurance = 2
    case z3Tempo = 3
    case z4Threshold = 4
    case z5VO2Max = 5

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .z1Recovery:  return "Z1 Recovery"
        case .z2Endurance: return "Z2 Endurance"
        case .z3Tempo:     return "Z3 Tempo"
        case .z4Threshold: return "Z4 Threshold"
        case .z5VO2Max:    return "Z5 VO2 Max"
        }
    }

    public var shortName: String { "Z\(rawValue)" }

    /// Upper bound as a fraction of LTHR (Friel LTHR model).
    public var upperFraction: Double {
        switch self {
        case .z1Recovery:  return 0.85   // < 85% LTHR
        case .z2Endurance: return 0.89   // 85–89%
        case .z3Tempo:     return 0.94   // 90–94%
        case .z4Threshold: return 1.05   // 95–105%
        case .z5VO2Max:    return .infinity // > 105%
        }
    }

    public var lowerFraction: Double {
        switch self {
        case .z1Recovery: return 0.0
        default: return HRZone(rawValue: rawValue - 1)!.upperFraction
        }
    }
}

/// Turns an LTHR into concrete BPM bands and classifies a live HR reading.
/// Mirrors `ZoneEngine`'s shape so views and summaries reuse the same patterns.
public struct HRZoneEngine: Sendable {
    /// Lactate threshold heart rate, in beats per minute.
    public let lthr: Int

    public init(lthr: Int) { self.lthr = lthr }

    public func bpmRange(for zone: HRZone) -> ClosedRange<Int> {
        let low = Int((Double(lthr) * zone.lowerFraction).rounded())
        let highFraction = zone.upperFraction.isFinite ? zone.upperFraction : 1.2
        let high = Int((Double(lthr) * highFraction).rounded())
        return low...high
    }

    /// Which zone a live HR reading falls into (for on-screen feedback).
    public func zone(forHR bpm: Int) -> HRZone {
        let fraction = Double(bpm) / Double(lthr)
        for z in HRZone.allCases where fraction <= z.upperFraction {
            return z
        }
        return .z5VO2Max
    }
}
