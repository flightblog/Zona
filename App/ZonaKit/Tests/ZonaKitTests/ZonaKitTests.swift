import Foundation
import Testing
@testable import ZonaKit

@Suite("Zone math")
struct ZoneMathTests {
    let engine = ZoneEngine(ftp: 200)

    @Test func z1Range() {
        #expect(engine.wattRange(for: .z1Recovery) == 0...110)
    }

    @Test func z2Range() {
        #expect(engine.wattRange(for: .z2Endurance) == 110...150)
    }

    @Test func z2SteadyTargetIsMidBand() {
        #expect(engine.steadyTarget(for: .z2Endurance) == 130)
    }

    @Test func classifyPowerIntoZone() {
        #expect(engine.zone(forPower: 90) == .z1Recovery)
        #expect(engine.zone(forPower: 130) == .z2Endurance)
        #expect(engine.zone(forPower: 210) == .z4Threshold)
    }

    /// The power bands are inclusive at BOTH ends and touch at their boundaries —
    /// at FTP 200, Z1 is 0…110 and Z2 is 110…150, so 110 belongs to two bands.
    /// `zone(forPower:)` is the tiebreak (`fraction <= upperFraction` in
    /// `PowerZone.allCases` order, so the LOWER zone wins the shared edge), and
    /// it's the only correct classifier. This is the power-side twin of the HR
    /// trap that `RideHRZoningTests.classifyingByBandScanWouldLandOnTheWrongZone`
    /// pins — scanning `wattRange`s to classify would be wrong here too, since
    /// Z1's band starts at 0 and underlaps every other band's floor.
    @Test func classifyPowerAtSharedBandEdges() {
        // Every shared edge lands in the lower of the two zones.
        #expect(engine.zone(forPower: 110) == .z1Recovery)   // Z1/Z2 edge
        #expect(engine.zone(forPower: 150) == .z2Endurance)  // Z2/Z3 edge
        #expect(engine.zone(forPower: 180) == .z3Tempo)      // Z3/Z4 edge
        #expect(engine.zone(forPower: 210) == .z4Threshold)  // Z4/Z5 edge
        #expect(engine.zone(forPower: 240) == .z5VO2Max)     // Z5/Z6 edge
        #expect(engine.zone(forPower: 300) == .z6Anaerobic)  // Z6/Z7 edge

        // One watt past each edge crosses into the upper zone.
        #expect(engine.zone(forPower: 111) == .z2Endurance)
        #expect(engine.zone(forPower: 151) == .z3Tempo)
        #expect(engine.zone(forPower: 181) == .z4Threshold)
        #expect(engine.zone(forPower: 211) == .z5VO2Max)
        #expect(engine.zone(forPower: 241) == .z6Anaerobic)
        #expect(engine.zone(forPower: 301) == .z7Neuromuscular)

        // Z1's band starts at 0, so it underlaps every other band's floor.
        #expect(engine.wattRange(for: .z1Recovery).lowerBound == 0)
        #expect(engine.zone(forPower: 0) == .z1Recovery)
    }

    /// Z7 has an infinite upper fraction, so it's the catch-all: no wattage,
    /// however implausible, classifies past it or falls through to a crash.
    @Test func z7AbsorbsEverythingAboveItsFloor() {
        #expect(engine.zone(forPower: 400) == .z7Neuromuscular)
        #expect(engine.zone(forPower: 2000) == .z7Neuromuscular)
        // `wattRange` substitutes 2×FTP for the infinite bound so the band is
        // renderable rather than unbounded.
        #expect(engine.wattRange(for: .z7Neuromuscular) == 300...400)
    }

    /// A zero/absent FTP (fresh install before the rider sets one) must not
    /// divide by zero — classification degrades to Z1 rather than crashing.
    @Test func zeroFTPClassifiesAsZ1WithoutDividingByZero() {
        let unset = ZoneEngine(ftp: 0)
        #expect(unset.zone(forPower: 0) == .z1Recovery)
        #expect(unset.zone(forPower: 250) == .z1Recovery)
    }

    @Test func steadyTargetPositionable() {
        // Lower edge of Z2 band.
        #expect(engine.steadyTarget(for: .z2Endurance, position: 0.0) == 110)
        #expect(engine.steadyTarget(for: .z2Endurance, position: 1.0) == 150)
    }
}

@Suite("FTMS encoding")
struct FTMSEncodingTests {
    @Test func setTargetPowerBytes() {
        let cmd = FTMS.setTargetPowerCommand(watts: 130) // 0x0082
        #expect(Array(cmd) == [0x05, 0x82, 0x00])
    }

    @Test func setTargetPowerLittleEndian() {
        let cmd = FTMS.setTargetPowerCommand(watts: 300) // 0x012C
        #expect(Array(cmd) == [0x05, 0x2C, 0x01])
    }

    @Test func stopBytes() {
        #expect(Array(FTMS.stopCommand()) == [0x08, 0x01])
    }

    @Test func parseSuccessResponse() {
        let r = FTMS.parseControlResponse(Data([0x80, 0x00, 0x01]))
        #expect(r?.requested == 0x00)
        #expect(r?.result == .success)
    }

    @Test func parseControlNotPermitted() {
        let r = FTMS.parseControlResponse(Data([0x80, 0x05, 0x05]))
        #expect(r?.result == .controlNotPermitted)
    }

    @Test func rejectsMalformedResponse() {
        #expect(FTMS.parseControlResponse(Data([0x01, 0x02])) == nil)
    }
}

@Suite("Indoor Bike Data decode")
struct IndoorBikeDataTests {
    @Test func decodesSpeedCadencePower() {
        // flags 0x0044 => cadence (bit2) + power (bit6); speed present (bit0 clear).
        var pkt = Data([0x44, 0x00])
        pkt.append(contentsOf: [0xE8, 0x03]) // speed 1000 => 10.00 km/h
        pkt.append(contentsOf: [0xB4, 0x00]) // cadence 180 => 90 rpm
        pkt.append(contentsOf: [0x82, 0x00]) // power 130 W
        let d = IndoorBikeData(pkt)
        #expect(d?.instantaneousSpeedKph == 10.0)
        #expect(d?.instantaneousCadenceRpm == 90.0)
        #expect(d?.instantaneousPowerW == 130)
    }

    @Test func powerOnlyPacket() {
        // flags 0x0041 => moreData bit set (no speed) + power.
        var pkt = Data([0x41, 0x00])
        pkt.append(contentsOf: [0x64, 0x00]) // power 100 W
        let d = IndoorBikeData(pkt)
        #expect(d?.instantaneousSpeedKph == nil)
        #expect(d?.instantaneousPowerW == 100)
    }

    @Test func rejectsTooShort() {
        #expect(IndoorBikeData(Data([0x00])) == nil)
    }
}

@Suite("Ride metrics")
struct RideMetricsTests {
    @Test func powerDelta() {
        var m = RideMetrics(powerW: 118, targetW: 130)
        #expect(m.powerDelta == -12)
        m.powerW = 140
        #expect(m.powerDelta == 10)
    }

    @Test func powerDeltaNilWithoutTarget() {
        #expect(RideMetrics(powerW: 118).powerDelta == nil)
    }

    /// Dead on target is 0, not nil — the ride screen distinguishes "exactly on
    /// target" (show a zero delta) from "no reading yet" (show nothing), and both
    /// existing tests only cover non-zero deltas, so an implementation returning
    /// nil for a zero difference would pass them.
    @Test func powerDeltaIsZeroWhenExactlyOnTarget() {
        #expect(RideMetrics(powerW: 130, targetW: 130).powerDelta == 0)
    }

    /// The other nil branch: a target is set but the trainer hasn't reported
    /// power yet (the gap between starting a ride and the first FTMS
    /// notification). `powerDeltaNilWithoutTarget` covers the mirror case.
    @Test func powerDeltaNilWithoutPowerReading() {
        #expect(RideMetrics(targetW: 130).powerDelta == nil)
        #expect(RideMetrics().powerDelta == nil)   // neither value present
    }
}
