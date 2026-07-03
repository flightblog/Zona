import Foundation
import Testing
@testable import ZonaKit

@Suite("HRR zone math")
struct HRRZoneMathTests {
    // maxHR 190, restingHR 50 → reserve 140. Boundaries are restingHR + f·reserve:
    // Z1 106–134, Z2 134–148, Z3 148–162, Z4 162–176, Z5 176–190.
    let engine = HRRZoneEngine(maxHR: 190, restingHR: 50)

    @Test func reserveIsMaxMinusResting() {
        #expect(engine.reserve == 140)
    }

    @Test func z1Range() {
        #expect(engine.bpmRange(for: .z1) == 106...134)
    }

    @Test func z2Range() {
        #expect(engine.bpmRange(for: .z2) == 134...148)
    }

    @Test func z3Range() {
        #expect(engine.bpmRange(for: .z3) == 148...162)
    }

    @Test func z4Range() {
        #expect(engine.bpmRange(for: .z4) == 162...176)
    }

    @Test func z5Range() {
        #expect(engine.bpmRange(for: .z5) == 176...190)
    }

    @Test func bandsAreContiguous() {
        // Each zone's upper bound is the next zone's lower bound.
        for z in [HRRZone.z1, .z2, .z3, .z4] {
            let next = HRRZone(rawValue: z.rawValue + 1)!
            #expect(engine.bpmRange(for: z).upperBound == engine.bpmRange(for: next).lowerBound)
        }
    }

    @Test func classifyHRIntoZone() {
        #expect(engine.zone(forHR: 120) == .z1)   // mid Z1
        #expect(engine.zone(forHR: 140) == .z2)   // mid Z2
        #expect(engine.zone(forHR: 155) == .z3)   // mid Z3
        #expect(engine.zone(forHR: 170) == .z4)   // mid Z4
        #expect(engine.zone(forHR: 185) == .z5)   // mid Z5
    }

    @Test func classifyAtBandEdges() {
        // A reading exactly on a boundary lands in the lower of the two zones
        // (upper bound is inclusive), matching bpmRange's closed ranges.
        #expect(engine.zone(forHR: 134) == .z1)
        #expect(engine.zone(forHR: 148) == .z2)
    }

    @Test func classifyBelowFloorAndAboveCeiling() {
        #expect(engine.zone(forHR: 80) == .z1)    // below Z1 floor → still Z1
        #expect(engine.zone(forHR: 210) == .z5)   // above max → Z5
    }

    @Test func degenerateReserveDoesNotCrash() {
        // maxHR == restingHR (no reserve): classification falls back to Z1.
        let flat = HRRZoneEngine(maxHR: 60, restingHR: 60)
        #expect(flat.reserve == 0)
        #expect(flat.zone(forHR: 60) == .z1)
    }
}

@Suite("HRR zone fractions")
struct HRRZoneFractionTests {
    @Test func z1FloorIsForty() {
        #expect(HRRZone.z1.lowerFraction == 0.40)
    }

    @Test func upperFractionsMatchWhoopBands() {
        #expect(HRRZone.z1.upperFraction == 0.60)
        #expect(HRRZone.z2.upperFraction == 0.70)
        #expect(HRRZone.z3.upperFraction == 0.80)
        #expect(HRRZone.z4.upperFraction == 0.90)
        #expect(HRRZone.z5.upperFraction == 1.00)
    }

    @Test func lowerChainsToPreviousUpper() {
        #expect(HRRZone.z2.lowerFraction == HRRZone.z1.upperFraction)
        #expect(HRRZone.z5.lowerFraction == HRRZone.z4.upperFraction)
    }
}
