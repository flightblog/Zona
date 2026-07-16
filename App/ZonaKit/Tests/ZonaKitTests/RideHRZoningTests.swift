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

    @Test func classifyingByBandScanWouldLandOnTheWrongZone() {
        // Guards the ride screen's live zone bar (and anything else tempted to
        // classify a reading by scanning `bpmRange`s). The bands are inclusive at
        // BOTH ends and touch at their boundaries — under LTHR 160, Z4 is 150…168
        // and Z5 is 168…192 — so "first band whose upperBound reaches the value"
        // is not a classifier: at Z1's floor of 0 it swallows everything, and at a
        // shared edge it can hand the beat to the wrong side. `zone(forHR:)` is the
        // one right answer, and it's what the ride's own scoring uses.
        let zoning = RideHRZoning.lthr(160)

        // 160 bpm is 100% of LTHR — threshold, squarely Z4. A naive scan over the
        // bands (Z1 = 0…136 first) reports Z5 here, which is what this pins against.
        #expect(zoning.zone(forHR: 160) == .z4Threshold)

        // Z1's band starts at 0 under the Friel model, so it overlaps every other
        // band's floor. Classification must not be confused by that.
        #expect(zoning.bpmRange(for: .z1Recovery).lowerBound == 0)
        #expect(zoning.zone(forHR: 150) == .z3Tempo)   // shared Z3/Z4 edge
        #expect(zoning.zone(forHR: 168) == .z4Threshold) // shared Z4/Z5 edge

        // And every zone's own band must classify back to itself at both ends.
        for zone in HRZone.allCases {
            let band = zoning.bpmRange(for: zone)
            #expect(zoning.zone(forHR: band.upperBound) == zone)
        }
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

    @Test func secondsInZoneClassifiesLikeSecondsPerZone() {
        // `secondsInZone` must count exactly the beats `secondsPerZone` (and the
        // live zone bar / BPM dial) put in that zone — it classifies via
        // `zone(forHR:)`, not membership of the rounded band. Under LTHR 160 the
        // Z2 band rounds to 136…142, but 136 is 85% of LTHR and classifies to Z1,
        // and 142 is 88.75% and classifies to Z2. A band-membership count would
        // wrongly include 136 (an edge the neighbouring zone owns).
        let zoning = RideHRZoning.lthr(160)
        let bpms = [136, 137, 142, 143]     // Z1, Z2, Z2, Z3 by the classifier
        #expect(zoning.secondsInZone(.z2Endurance, bpms: bpms) == 2)
        // Agreement with the per-zone bucketer, beat for beat, across all zones.
        let perZone = zoning.secondsPerZone(bpms: bpms)
        for zone in HRZone.allCases {
            #expect(zoning.secondsInZone(zone, bpms: bpms) == (perZone[zone.rawValue] ?? 0))
        }
    }

    @Test func secondsInZoneClassifiesLikeSecondsPerZoneUnderWhoop() {
        // The same agreement must hold on the WHOOP/HRR path, whose bands round
        // differently from Friel's. With max 190 / resting 50 (reserve 140) the Z2
        // band tops out at 70% HRR = 148 bpm, so 148 is Z2 but 149 (70.7%) is Z3.
        // Band membership would drift here just as it does under LTHR.
        let zoning = RideHRZoning.whoopHRR(maxHR: 190, restingHR: 50, lthr: 160)
        let bpms = [134, 148, 149, 163]     // Z1, Z2, Z3, Z4 by the classifier
        #expect(zoning.secondsInZone(.z2Endurance, bpms: bpms) == 1)
        let perZone = zoning.secondsPerZone(bpms: bpms)
        for zone in HRZone.allCases {
            #expect(zoning.secondsInZone(zone, bpms: bpms) == (perZone[zone.rawValue] ?? 0))
        }
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
