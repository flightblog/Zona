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

/// Should the hub attach `candidate` as the connected device for `kind`?
///
/// Pure decision, factored out of the CoreBluetooth delegate so it's unit-tested
/// without a live central. The rule: if the user pinned a preferred device for
/// this kind, only that exact device qualifies; otherwise any candidate does
/// (first-to-connect, the original behavior).
public func shouldAttach(candidate: UUID,
                         forKind kind: SensorKind,
                         preferred: UUID?) -> Bool {
    guard let preferred else { return true }
    return candidate == preferred
}

/// A source-agnostic decoded update. Any sensor produces one of these; the hub
/// folds the non-nil fields into the live `RideMetrics`.
public struct SensorReading: Sendable, Equatable {
    public var powerW: Int?
    public var cadenceRpm: Int?
    public var speedKph: Double?
    public var heartRateBpm: Int?
    /// Power (W) from a standalone cycling power meter (SRAM/Quarq), kept
    /// deliberately SEPARATE from `powerW`. `powerW` is the trainer's own power —
    /// it drives ERG, recording, zone math, and the Strava export. The power
    /// meter is a display-only secondary readout, so it never merges into
    /// `powerW` and can't contaminate any of that.
    public var powerMeterW: Int?
    /// R-R (beat-to-beat) intervals in seconds from this HR notification, if the
    /// strap reports them (many do; the trainer never will). Feeds HRV. Bursty —
    /// a single packet can carry several — so unlike the other fields these are
    /// *appended* per second by the recorder, not last-write-wins.
    public var rrIntervalsSec: [Double]?

    public init(powerW: Int? = nil,
                cadenceRpm: Int? = nil,
                speedKph: Double? = nil,
                heartRateBpm: Int? = nil,
                powerMeterW: Int? = nil,
                rrIntervalsSec: [Double]? = nil) {
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
        self.powerMeterW = powerMeterW
        self.rrIntervalsSec = rrIntervalsSec
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

/// A sensor surfaced by a browse (discovery) scan but NOT yet committed to a
/// connection. This is what the "pick your device" list renders. `id` is the
/// CoreBluetooth peripheral identifier — stable per device on this machine, and
/// what gets persisted as the preferred choice.
public struct DiscoveredSensor: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let kind: SensorKind
    /// Advertised signal strength, if known (higher = closer).
    public var rssi: Int?

    public init(id: UUID, name: String, kind: SensorKind, rssi: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rssi = rssi
    }
}

/// Persistence seam for remembering which physical device to use per kind.
/// ZonaKit stays storage-agnostic; the app supplies a UserDefaults-backed impl.
///
/// Two distinct notions, deliberately separate:
/// - **preferred** — an *explicit user choice* ("use THIS strap"). When set, the
///   hub connects only this device for the kind and ignores other candidates.
/// - **remembered** — the last device that actually connected, for silent
///   auto-reconnect. Preferred always wins over remembered when both exist.
public protocol SensorMemory: Sendable {
    /// The last peripheral identifier auto-connected for `kind`, if any.
    func rememberedIdentifier(for kind: SensorKind) -> UUID?
    /// Record `identifier` as the last-connected device for `kind`.
    func remember(_ identifier: UUID, for kind: SensorKind)

    /// The user's explicitly chosen device for `kind`, if they pinned one.
    func preferredIdentifier(for kind: SensorKind) -> UUID?
    /// Pin `identifier` as the preferred device for `kind` (nil clears it,
    /// restoring first-to-connect behavior).
    func setPreferred(_ identifier: UUID?, for kind: SensorKind)
}

/// A no-op memory (used by previews/tests that don't care about persistence).
public struct EphemeralSensorMemory: SensorMemory {
    public init() {}
    public func rememberedIdentifier(for kind: SensorKind) -> UUID? { nil }
    public func remember(_ identifier: UUID, for kind: SensorKind) {}
    public func preferredIdentifier(for kind: SensorKind) -> UUID? { nil }
    public func setPreferred(_ identifier: UUID?, for kind: SensorKind) {}
}
