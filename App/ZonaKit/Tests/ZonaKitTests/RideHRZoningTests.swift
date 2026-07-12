import Testing
@testable import ZonaKit

/// `RideHRZoning` is the single place that decides *which* HR-zone model a ride is
/// scored against, so these cover the two things that can silently restate a
/// rider's history: picking the wrong model, and losing the model on a
/// storage round-trip.
struct RideHRZoningTests {

    // MARK: Choosing the model

    @Test func resolvesToWhoopWhenBothInputsPresent() {
        let zoning = RideHRZoning.resolve(maxHR: 190, restingHR: 50, lthr: 160)
        #expect(zoning == .whoopHRR(maxHR: 190, restingHR: 50, lthr: 160))
        #expect(zoning.isWhoop)
    }

    @Test func resolvesToLTHRWhenWhoopInputsMissing() {
        // A ride saved before WHOOP zoning existed reads back with both fields nil
        // and must keep scoring exactly as it always did.
        #expect(RideHRZoning.resolve(maxHR: nil, restingHR: nil, lthr: 160) == .lthr(160))
        #expect(RideHRZoning.resolve(maxHR: 190, restingHR: nil, lthr: 160) == .lthr(160))
        #expect(RideHRZoning.resolve(maxHR: nil, restingHR: 50, lthr: 160) == .lthr(160))
        #expect(!RideHRZoning.resolve(maxHR: nil, restingHR: nil, lthr: 160).isWhoop)
    }

    @Test func resolvesToLTHRWhenReserveWouldBeNonPositive() {
        // Max at or below resting HR means a zero/negative heart-rate reserve —
        // Karvonen would divide into nonsense, so fall back rather than emit
        // garbage bands.
        #expect(RideHRZoning.resolve(maxHR: 50, restingHR: 50, lthr: 160) == .lthr(160))
        #expect(RideHRZoning.resolve(maxHR: 40, restingHR: 50, lthr: 160) == .lthr(160))
    }

    // MARK: Agreement with the underlying engines
    //
    // The zoning is a facade: it must not invent its own math, just dispatch to
    // HRZoneEngine / HRRZoneEngine. These pin it to them.

    @Test func lthrZoningMatchesHRZoneEngine() {
        let zoning = RideHRZoning.lthr(160)
        let engine = HRZoneEngine(lthr: 160)
        for zone in HRZone.allCases {
            #expect(zoning.bpmRange(for: zone) == engine.bpmRange(for: zone))
        }
        for bpm in [90, 130, 140, 147, 160, 175, 200] {
            #expect(zoning.zone(forHR: bpm) == engine.zone(forHR: bpm))
        }
    }

    @Test func whoopZoningMatchesHRRZoneEngine() {
        let zoning = RideHRZoning.whoopHRR(maxHR: 190, restingHR: 50, lthr: 160)
        let engine = HRRZoneEngine(maxHR: 190, restingHR: 50)
        for zone in HRZone.allCases {
            let hrrZone = HRRZone(rawValue: zone.rawValue)!
            #expect(zoning.bpmRange(for: zone) == engine.bpmRange(for: hrrZone))
        }
        for bpm in [90, 130, 140, 147, 160, 175, 200] {
            #expect(zoning.zone(forHR: bpm).rawValue == engine.zone(forHR: bpm).rawValue)
        }
    }

    @Test func theTwoModelsDisagree() {
        // The premise of the whole type: at the same HR the models can name
        // different zones, so which one a ride carries genuinely changes its stats.
        let lthr = RideHRZoning.lthr(160)                                    // Z2 = 136…142
        let whoop = RideHRZoning.whoopHRR(maxHR: 190, restingHR: 50, lthr: 160) // Z2 = 134…148
        #expect(lthr.bpmRange(for: .z2Endurance) == 136...142)
        #expect(whoop.bpmRange(for: .z2Endurance) == 134...148)
        // 147 bpm is 92% of LTHR → Z3 Tempo, but only 69% of a 140-beat reserve
        // → still Z2 Endurance under WHOOP. Same heart rate, different zone.
        #expect(lthr.zone(forHR: 147) == .z3Tempo)
        #expect(whoop.zone(forHR: 147) == .z2Endurance)
    }

    // MARK: Bucketing

    @Test func secondsPerZoneBucketsEachReadingExactlyOnce() {
        let zoning = RideHRZoning.lthr(160)
        // 130 → Z1, 140 ×2 → Z2, 147 → Z3, 200 → Z5.
        let buckets = zoning.secondsPerZone(bpms: [130, 140, 140, 147, 200])
        #expect(buckets[HRZone.z1Recovery.rawValue] == 1)
        #expect(buckets[HRZone.z2Endurance.rawValue] == 2)
        #expect(buckets[HRZone.z3Tempo.rawValue] == 1)
        #expect(buckets[HRZone.z5VO2Max.rawValue] == 1)
        // Zones with no time are omitted, and every second lands somewhere.
        #expect(buckets[HRZone.z4Threshold.rawValue] == nil)
        #expect(buckets.values.reduce(0, +) == 5)
    }

    @Test func secondsPerZoneBucketsUnderWhoopBands() {
        let zoning = RideHRZoning.whoopHRR(maxHR: 190, restingHR: 50, lthr: 160)
        // Under WHOOP's bands 147 is Z2, where LTHR 160 would have called it Z3.
        let buckets = zoning.secondsPerZone(bpms: [140, 147])
        #expect(buckets[HRZone.z2Endurance.rawValue] == 2)
        #expect(buckets[HRZone.z3Tempo.rawValue] == nil)
    }

    @Test func secondsInZoneCountsOnlyTheTargetBand() {
        let zoning = RideHRZoning.lthr(160)
        #expect(zoning.secondsInZone(.z2Endurance, bpms: [120, 140, 140, 140, 150]) == 3)
        #expect(zoning.secondsInZone(.z2Endurance, bpms: []) == 0)
    }

    // MARK: Persistence round-trip

    @Test func whoopZoningRoundTripsThroughStoredColumns() {
        let original = RideHRZoning.whoopHRR(maxHR: 190, restingHR: 50, lthr: 160)
        #expect(original.storedLTHR == 160)
        #expect(original.storedWhoopMaxHR == 190)
        #expect(original.storedWhoopRestingHR == 50)

        let restored = RideHRZoning.resolve(maxHR: original.storedWhoopMaxHR,
                                            restingHR: original.storedWhoopRestingHR,
                                            lthr: original.storedLTHR)
        #expect(restored == original)
    }

    @Test func lthrZoningRoundTripsWithNilWhoopColumns() {
        let original = RideHRZoning.lthr(155)
        #expect(original.storedLTHR == 155)
        #expect(original.storedWhoopMaxHR == nil)
        #expect(original.storedWhoopRestingHR == nil)

        let restored = RideHRZoning.resolve(maxHR: original.storedWhoopMaxHR,
                                            restingHR: original.storedWhoopRestingHR,
                                            lthr: original.storedLTHR)
        #expect(restored == original)
    }
}
