import Foundation

/// Decodes the standard BLE Cycling Power Measurement characteristic (`0x2A63`)
/// from the Cycling Power Service (`0x1818`). The SRAM/Quarq power meter speaks
/// this.
///
/// Layout: `[flags: UInt16 LE][instantaneous power: SInt16 LE][...optional
/// fields]`. Instantaneous power sits at a fixed offset (right after the flags).
/// The optional fields that follow are each gated by a flag bit and appear in a
/// FIXED order, so to reach a later one (crank revolutions) we must know the
/// size of every present earlier one and walk past it.
///
/// We decode three things the Quarq reports: instantaneous power, pedal-power
/// balance (L/R %), and crank-revolution data. Cadence isn't in the packet
/// directly — it's derived from the change in cumulative crank revolutions over
/// the change in crank-event time between two packets (see `SensorHub`), so here
/// we just surface the raw revolution counters.
public struct CyclingPowerMeasurement: Sendable, Equatable {
    public let instantaneousPowerW: Int

    /// Pedal power balance as a percentage 0–100 (the share attributed to one
    /// leg, per the reference bit; nil when the meter doesn't report it). A Quarq
    /// DZero/AXS reports this; single-sided meters may omit it.
    public let pedalPowerBalancePercent: Double?

    /// Cumulative crank revolutions (wraps at UInt16), paired with the time of the
    /// last crank event in 1/1024 s units. nil when the meter doesn't report crank
    /// data. Feeds cadence via the delta between successive packets.
    public let cumulativeCrankRevolutions: Int?
    public let lastCrankEventTime: Int?

    // Flag bits (Cycling Power Measurement, 0x2A63), least-significant first.
    private static let pedalPowerBalancePresent: UInt16 = 1 << 0
    private static let accumulatedTorquePresent: UInt16 = 1 << 2
    private static let wheelRevolutionDataPresent: UInt16 = 1 << 4
    private static let crankRevolutionDataPresent: UInt16 = 1 << 5

    public init?(_ data: Data) {
        // 2 bytes flags + 2 bytes signed power are mandatory.
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        instantaneousPowerW = Int(Int16(bitPattern: UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)))

        // Walk the optional fields in their fixed spec order, advancing `offset`
        // past each present one so later fields land at the right place. Bail out
        // (leave the rest nil) if a field would read past the packet's end.
        var offset = 4

        func readUInt16() -> Int? {
            guard offset + 2 <= bytes.count else { return nil }
            let v = Int(UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
            offset += 2
            return v
        }

        // 1. Pedal power balance (UInt8, unit 1/2 %). A following reference bit
        //    (1 << 1) says which leg it's for; we surface the raw percentage.
        var balance: Double?
        if flags & Self.pedalPowerBalancePresent != 0 {
            if offset + 1 <= bytes.count {
                balance = Double(bytes[offset]) / 2.0
                offset += 1
            }
        }
        pedalPowerBalancePercent = balance

        // 2. Accumulated torque (UInt16) — we don't use it, but must skip it so
        //    the crank-revolution field that follows lands at the right offset.
        if flags & Self.accumulatedTorquePresent != 0 { _ = readUInt16() }

        // 3. Wheel revolution data (UInt32 cumulative + UInt16 event time) — a
        //    crank meter won't send this, but skip it if present. 6 bytes total.
        if flags & Self.wheelRevolutionDataPresent != 0 {
            if offset + 6 <= bytes.count { offset += 6 } else { offset = bytes.count }
        }

        // 4. Crank revolution data: UInt16 cumulative revolutions + UInt16 last
        //    crank event time (1/1024 s). This is what cadence is derived from.
        if flags & Self.crankRevolutionDataPresent != 0 {
            cumulativeCrankRevolutions = readUInt16()
            lastCrankEventTime = readUInt16()
        } else {
            cumulativeCrankRevolutions = nil
            lastCrankEventTime = nil
        }
    }
}
