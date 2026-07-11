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

    /// Live watts from a connected SRAM/Quarq power meter, shown on the ride
    /// screen as a secondary readout. Purely informational: `RideRecorder`,
    /// `RideSummary`, the TCX export, and every zone calculation ignore it — only
    /// `powerW` (the trainer) feeds those. Keeping it here (not merged into
    /// `powerW`) is what guarantees the meter can't skew recorded/exported data.
    ///
    /// Why this reads DIFFERENTLY from `powerW`, and why that's expected:
    /// The two devices measure different physical quantities at different points
    /// on the drivetrain. Both send instantaneous power as a signed 16-bit LE
    /// integer in watts, so the *decoding* is equivalent (see
    /// `CyclingPowerMeasurement` for the Quarq's 0x2A63, `IndoorBikeData` for the
    /// trainer's 0x2AD2) — the difference is entirely upstream in how each watt
    /// value is produced:
    ///   • Quarq (crank/spider meter): DIRECT measurement. Strain gauges in the
    ///     crank flex under pedaling force → torque; combined with cadence →
    ///     power (P = torque × angular velocity). Measures your leg input at the
    ///     TOP of the drivetrain, before the chain/cassette/pulleys.
    ///   • Kickr (smart trainer): ESTIMATED from its known resistance curve and
    ///     flywheel speed — no strain gauge on your drivetrain. Measures what
    ///     reaches the flywheel, at the BOTTOM of the drivetrain.
    /// So the trainer typically reads a few watts LOWER than the Quarq for the
    /// same effort: ~2–4% is lost to chain/bottom-bracket friction between the
    /// cranks and the flywheel, plus the trainer's estimate carries its own error
    /// band and averaging window. A small steady-state gap is the drivetrain
    /// loss, not a bug — which is exactly why the trainer stays the source of
    /// truth and the meter is display-only.
    public var powerMeterW: Int?

    /// Cadence (rpm) from the SRAM/Quarq's crank-revolution data. Display-only,
    /// like `powerMeterW` — separate from the trainer-derived `cadenceRpm` that
    /// drives the cadence dial, and never recorded or exported.
    public var powerMeterCadenceRpm: Int?

    /// Pedal power balance (L/R) from the SRAM/Quarq, as one leg's share 0–100 %.
    /// Display-only; nil when the meter doesn't report balance.
    public var powerMeterBalancePercent: Double?

    /// The ERG watt target currently commanded (nil before a ride starts).
    public var targetW: Int?

    /// R-R intervals (seconds) from the most recent HR notification, if any.
    /// **Transient, not sticky:** the hub publishes these once with the reading
    /// that carried them and then clears them, so a given beat set is recorded in
    /// exactly one second's sample and never re-counted on a later metrics change.
    public var rrIntervalsSec: [Double]?

    public init(powerW: Int? = nil,
                cadenceRpm: Int? = nil,
                speedKph: Double? = nil,
                heartRateBpm: Int? = nil,
                powerMeterW: Int? = nil,
                powerMeterCadenceRpm: Int? = nil,
                powerMeterBalancePercent: Double? = nil,
                targetW: Int? = nil,
                rrIntervalsSec: [Double]? = nil) {
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
        self.powerMeterW = powerMeterW
        self.powerMeterCadenceRpm = powerMeterCadenceRpm
        self.powerMeterBalancePercent = powerMeterBalancePercent
        self.targetW = targetW
        self.rrIntervalsSec = rrIntervalsSec
    }

    /// Signed deviation of live power from target (negative = under target).
    public var powerDelta: Int? {
        guard let powerW, let targetW else { return nil }
        return powerW - targetW
    }
}
