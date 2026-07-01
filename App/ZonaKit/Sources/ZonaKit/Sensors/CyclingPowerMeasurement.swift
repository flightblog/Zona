import Foundation

/// Decodes the standard BLE Cycling Power Measurement characteristic (`0x2A63`)
/// from the Cycling Power Service (`0x1818`). The SRAM/Quarq power meter speaks
/// this. Built now (tiny + testable) so the power meter drops in as a power
/// source later with no new plumbing.
///
/// Layout: [flags: UInt16 LE][instantaneous power: SInt16 LE][...optional fields].
/// Instantaneous power sits at a fixed offset (right after the flags), so we can
/// read it without walking the optional fields. Crank/wheel revolution data
/// (for cadence) lives in later, flag-gated fields — deferred for now.
public struct CyclingPowerMeasurement: Sendable, Equatable {
    public let instantaneousPowerW: Int

    public init?(_ data: Data) {
        // 2 bytes flags + 2 bytes signed power.
        guard data.count >= 4 else { return nil }
        let raw = Int16(bitPattern: UInt16(data[2]) | (UInt16(data[3]) << 8))
        instantaneousPowerW = Int(raw)
    }
}
