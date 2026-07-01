import Foundation

/// Where we are in the connect → control lifecycle. Drives the UI's top-level
/// state. Kept small and linear so views can switch over it exhaustively.
public enum ConnectionState: Equatable, Sendable {
    case idle
    case bluetoothUnavailable(reason: String)
    case scanning
    case connecting(name: String)
    case preparing            // discovering services / requesting control
    case ready(name: String)  // in control, ERG session started
    case disconnected(error: String?)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .preparing: return true
        default: return false
        }
    }
}

/// Latest live values from the trainer, plus the app's derived state (target,
/// live zone). This is what the ride screen renders.
public struct RideMetrics: Equatable, Sendable {
    public var powerW: Int?
    public var cadenceRpm: Int?
    public var speedKph: Double?
    public var heartRateBpm: Int?

    /// The ERG watt target currently commanded (nil before a ride starts).
    public var targetW: Int?

    public init(powerW: Int? = nil,
                cadenceRpm: Int? = nil,
                speedKph: Double? = nil,
                heartRateBpm: Int? = nil,
                targetW: Int? = nil) {
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
        self.targetW = targetW
    }

    /// Signed deviation of live power from target (negative = under target).
    public var powerDelta: Int? {
        guard let powerW, let targetW else { return nil }
        return powerW - targetW
    }
}
