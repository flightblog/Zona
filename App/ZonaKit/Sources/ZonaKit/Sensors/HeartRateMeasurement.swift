import Foundation

/// Decodes the standard BLE Heart Rate Measurement characteristic (`0x2A37`)
/// from the Heart Rate Service (`0x180D`). The Garmin HRM 200 — like any
/// standards-compliant strap, and Whoop over BLE — speaks exactly this.
///
/// Layout: [flags: UInt8][HR value: UInt8 or UInt16 LE][energy?][RR intervals?]
/// Flags bit0: 0 ⇒ HR is UInt8, 1 ⇒ HR is UInt16.
///        bit3: energy-expended field present (UInt16).
///        bit4: one or more RR-interval values follow (UInt16 each, 1/1024 s).
public struct HeartRateMeasurement: Sendable, Equatable {
    public let heartRateBpm: Int
    /// R-R intervals in seconds, if the sensor reports them. Parsed but unused
    /// for now; kept so HRV can be added later without touching the wire format.
    public let rrIntervals: [Double]

    public init?(_ data: Data) {
        guard data.count >= 2 else { return nil }
        let flags = data[0]
        var offset = 1

        let is16Bit = (flags & 0x01) != 0
        if is16Bit {
            guard offset + 1 < data.count else { return nil }
            heartRateBpm = Int(UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
            offset += 2
        } else {
            guard offset < data.count else { return nil }
            heartRateBpm = Int(data[offset])
            offset += 1
        }

        // Skip energy-expended (UInt16) if present.
        if (flags & 0x08) != 0 { offset += 2 }

        // R-R intervals: remaining bytes, UInt16 LE, units of 1/1024 s.
        var rr: [Double] = []
        if (flags & 0x10) != 0 {
            while offset + 1 < data.count {
                let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                rr.append(Double(raw) / 1024.0)
                offset += 2
            }
        }
        rrIntervals = rr
    }
}
