import CoreBluetooth
import Foundation

/// A class of BLE fitness sensor Zona can talk to, identified by its primary
/// GATT service. Adding a sensor type = adding a case here; a Whoop band
/// exposing standard HR needs no new case (it's a `.heartRate` source).
public enum SensorKind: String, CaseIterable, Sendable, Identifiable {
    case trainer      // FTMS smart trainer (Kickr Core 2)
    case heartRate    // HR strap (Garmin HRM 200, Whoop, …)
    case powerMeter   // Cycling power meter (SRAM/Quarq)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .trainer:    return "Trainer"
        case .heartRate:  return "Heart rate"
        case .powerMeter: return "Power meter"
        }
    }

    /// The primary service to scan for and match on discovery.
    public var serviceUUIDString: String {
        switch self {
        case .trainer:    return FTMS.UUIDs.service   // 1826
        case .heartRate:  return "180D"
        case .powerMeter: return "1818"
        }
    }

    public var serviceUUID: CBUUID { CBUUID(string: serviceUUIDString) }

    /// The notify characteristic carrying live measurements for this kind.
    public var measurementUUIDString: String {
        switch self {
        case .trainer:    return FTMS.UUIDs.indoorBikeData // 2AD2
        case .heartRate:  return "2A37"
        case .powerMeter: return "2A63"
        }
    }

    public var measurementUUID: CBUUID { CBUUID(string: measurementUUIDString) }

    /// Match a kind from an advertised/discovered service UUID.
    public static func from(serviceUUID: CBUUID) -> SensorKind? {
        allCases.first { $0.serviceUUID == serviceUUID }
    }
}

/// A source-agnostic decoded update. Any sensor produces one of these; the hub
/// folds the non-nil fields into the live `RideMetrics`.
public struct SensorReading: Sendable, Equatable {
    public var powerW: Int?
    public var cadenceRpm: Int?
    public var speedKph: Double?
    public var heartRateBpm: Int?

    public init(powerW: Int? = nil,
                cadenceRpm: Int? = nil,
                speedKph: Double? = nil,
                heartRateBpm: Int? = nil) {
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
    }
}

/// Per-sensor connection lifecycle. Independent per kind, so one sensor can be
/// live while another is still searching.
public enum SensorConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting(name: String)
    case connected(name: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Persistence seam for "remember the exact device we paired." ZonaKit stays
/// storage-agnostic; the app supplies a UserDefaults-backed implementation.
public protocol SensorMemory: Sendable {
    /// The last peripheral identifier auto-connected for `kind`, if any.
    func rememberedIdentifier(for kind: SensorKind) -> UUID?
    /// Record `identifier` as the preferred device for `kind`.
    func remember(_ identifier: UUID, for kind: SensorKind)
}

/// A no-op memory (used by previews/tests that don't care about persistence).
public struct EphemeralSensorMemory: SensorMemory {
    public init() {}
    public func rememberedIdentifier(for kind: SensorKind) -> UUID? { nil }
    public func remember(_ identifier: UUID, for kind: SensorKind) {}
}
