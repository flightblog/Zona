import CoreBluetooth
import Foundation

// MARK: - FTMS GATT identifiers
//
// Fitness Machine Service — the open Bluetooth SIG standard that the Kickr
// Core 2 exposes (firmware >= 1.1.1). This is what actually lets you control
// the trainer in real time; the Wahoo Cloud REST API cannot do this.
//
// Spec: Bluetooth SIG "Fitness Machine Service" v1.0.

enum FTMS {
    static let service = CBUUID(string: "1826")
    static let indoorBikeData = CBUUID(string: "2AD2")   // notify: live power/cadence/speed
    static let controlPoint = CBUUID(string: "2AD9")     // write + indicate: commands
    static let machineStatus = CBUUID(string: "2ADA")    // notify: state changes (optional)

    // Control Point op codes (first byte of a write to 0x2AD9).
    enum OpCode: UInt8 {
        case requestControl = 0x00
        case reset          = 0x01
        case setTargetPower = 0x05   // ERG mode: hold N watts. Param: Int16 LE watts.
        case startOrResume  = 0x07
        case stopOrPause    = 0x08   // Param: 0x01 = stop, 0x02 = pause
    }

    // Response op code that prefixes every Control Point indication.
    static let responseOpCode: UInt8 = 0x80

    enum ResultCode: UInt8 {
        case success            = 0x01
        case opCodeNotSupported = 0x02
        case invalidParameter   = 0x03
        case operationFailed    = 0x04
        case controlNotPermitted = 0x05

        var isSuccess: Bool { self == .success }
    }
}

// MARK: - Control Point command encoding

extension FTMS {
    static func requestControlCommand() -> Data {
        Data([OpCode.requestControl.rawValue])
    }

    static func startCommand() -> Data {
        Data([OpCode.startOrResume.rawValue])
    }

    static func stopCommand() -> Data {
        Data([OpCode.stopOrPause.rawValue, 0x01]) // 0x01 = stop
    }

    /// ERG mode: instruct the trainer to hold `watts`, regardless of cadence.
    /// Parameter is a signed 16-bit little-endian integer, in watts.
    static func setTargetPowerCommand(watts: Int) -> Data {
        let clamped = Int16(clamping: watts)
        var body = Data([OpCode.setTargetPower.rawValue])
        withUnsafeBytes(of: clamped.littleEndian) { body.append(contentsOf: $0) }
        return body
    }

    /// Parse a Control Point indication of the form:
    /// [0x80][requestedOpCode][resultCode]...
    static func parseControlResponse(_ data: Data) -> (requested: UInt8, result: ResultCode)? {
        guard data.count >= 3, data[0] == responseOpCode else { return nil }
        let requested = data[1]
        let result = ResultCode(rawValue: data[2]) ?? .operationFailed
        return (requested, result)
    }
}

// MARK: - Indoor Bike Data decoding (0x2AD2)
//
// The characteristic starts with a 16-bit flags field. Each flag bit that is
// set adds a field, in a fixed order, to the packet. We only need power,
// cadence and speed, but we must walk every preceding field to find them
// because offsets are dynamic.

struct IndoorBikeData {
    var instantaneousSpeedKph: Double?
    var instantaneousCadenceRpm: Double?
    var instantaneousPowerW: Int?
    var heartRateBpm: Int?

    init?(_ data: Data) {
        guard data.count >= 2 else { return nil }
        let flags = UInt16(data[0]) | (UInt16(data[1]) << 8)
        var offset = 2

        func readU16() -> UInt16? {
            guard offset + 1 < data.count else { return nil }
            let v = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            offset += 2
            return v
        }
        func readS16() -> Int16? { readU16().map { Int16(bitPattern: $0) } }
        func readU8() -> UInt8? {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return data[offset]
        }

        // Bit 0 INVERTED: 0 => Instantaneous Speed IS present (quirk of the spec).
        let moreDataOnly = (flags & 0x0001) != 0
        if !moreDataOnly {
            if let raw = readU16() { instantaneousSpeedKph = Double(raw) * 0.01 } // 0.01 km/h
        }
        if (flags & 0x0002) != 0 { _ = readU16() }                 // Average Speed
        if (flags & 0x0004) != 0 {                                 // Instantaneous Cadence
            if let raw = readU16() { instantaneousCadenceRpm = Double(raw) * 0.5 } // 0.5 rpm
        }
        if (flags & 0x0008) != 0 { _ = readU16() }                 // Average Cadence
        if (flags & 0x0010) != 0 { offset += 3 }                   // Total Distance (uint24)
        if (flags & 0x0020) != 0 { _ = readS16() }                 // Resistance Level
        if (flags & 0x0040) != 0 {                                 // Instantaneous Power
            if let raw = readS16() { instantaneousPowerW = Int(raw) }
        }
        if (flags & 0x0080) != 0 { _ = readS16() }                 // Average Power
        if (flags & 0x0100) != 0 { offset += 5 }                   // Expended Energy (3x fields)
        if (flags & 0x0200) != 0 {                                 // Heart Rate (uint8)
            if let raw = readU8() { heartRateBpm = Int(raw) }
        }
        // Remaining fields (metabolic equivalent, elapsed/remaining time) ignored.
    }
}
