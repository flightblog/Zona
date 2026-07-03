import Foundation

/// Coggan power zones from FTP. Pure logic, no Bluetooth. This decides "what
/// watts should I hold to ride steadily in Zone 1/2".
public enum PowerZone: Int, CaseIterable, Sendable, Identifiable {
    case z1Recovery = 1
    case z2Endurance = 2
    case z3Tempo = 3
    case z4Threshold = 4
    case z5VO2Max = 5
    case z6Anaerobic = 6
    case z7Neuromuscular = 7

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .z1Recovery:      return "Z1 Recovery"
        case .z2Endurance:     return "Z2 Endurance"
        case .z3Tempo:         return "Z3 Tempo"
        case .z4Threshold:     return "Z4 Threshold"
        case .z5VO2Max:        return "Z5 Max"
        case .z6Anaerobic:     return "Z6 Anaerobic"
        case .z7Neuromuscular: return "Z7 Neuromuscular"
        }
    }

    public var shortName: String {
        switch self {
        case .z1Recovery:      return "Z1"
        case .z2Endurance:     return "Z2"
        case .z3Tempo:         return "Z3"
        case .z4Threshold:     return "Z4"
        case .z5VO2Max:        return "Z5"
        case .z6Anaerobic:     return "Z6"
        case .z7Neuromuscular: return "Z7"
        }
    }

    /// Fraction-of-FTP upper bound. Standard Coggan 7-zone model.
    public var upperFraction: Double {
        switch self {
        case .z1Recovery:      return 0.55
        case .z2Endurance:     return 0.75
        case .z3Tempo:         return 0.90
        case .z4Threshold:     return 1.05
        case .z5VO2Max:        return 1.20
        case .z6Anaerobic:     return 1.50
        case .z7Neuromuscular: return .infinity
        }
    }

    public var lowerFraction: Double {
        switch self {
        case .z1Recovery: return 0.0
        default: return PowerZone(rawValue: rawValue - 1)!.upperFraction
        }
    }
}

public struct ZoneEngine: Sendable {
    /// Functional Threshold Power, in watts.
    public let ftp: Int

    public init(ftp: Int) { self.ftp = ftp }

    public func wattRange(for zone: PowerZone) -> ClosedRange<Int> {
        let low = Int((Double(ftp) * zone.lowerFraction).rounded())
        let highFraction = zone.upperFraction.isFinite ? zone.upperFraction : 2.0
        let high = Int((Double(ftp) * highFraction).rounded())
        return low...high
    }

    /// A single steady ERG setpoint for the chosen zone. Defaults to the
    /// middle of the band — a sensible "hold here all ride" target.
    public func steadyTarget(for zone: PowerZone, position: Double = 0.5) -> Int {
        let range = wattRange(for: zone)
        let span = Double(range.upperBound - range.lowerBound)
        return range.lowerBound + Int((span * position).rounded())
    }

    /// Which zone a live power reading falls into (for on-screen feedback).
    public func zone(forPower watts: Int) -> PowerZone {
        let fraction = Double(watts) / Double(ftp)
        for z in PowerZone.allCases where fraction <= z.upperFraction {
            return z
        }
        return .z7Neuromuscular
    }
}
