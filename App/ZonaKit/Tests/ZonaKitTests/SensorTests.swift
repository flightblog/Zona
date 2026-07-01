import Foundation
import Testing
@testable import ZonaKit

@Suite("Heart rate measurement decode")
struct HeartRateMeasurementTests {
    @Test func decodes8BitHeartRate() {
        // flags 0x00 (8-bit, no RR), HR 72.
        let d = HeartRateMeasurement(Data([0x00, 0x48]))
        #expect(d?.heartRateBpm == 72)
        #expect(d?.rrIntervals.isEmpty == true)
    }

    @Test func decodes16BitHeartRate() {
        // flags 0x01 (16-bit), HR 300 (0x012C) LE.
        let d = HeartRateMeasurement(Data([0x01, 0x2C, 0x01]))
        #expect(d?.heartRateBpm == 300)
    }

    @Test func decodesRRIntervals() {
        // flags 0x10 (RR present), HR 60, one RR = 1024 (=> 1.0 s).
        let d = HeartRateMeasurement(Data([0x10, 0x3C, 0x00, 0x04]))
        #expect(d?.heartRateBpm == 60)
        #expect(d?.rrIntervals == [1.0])
    }

    @Test func skipsEnergyBeforeRR() {
        // flags 0x18 (energy + RR), HR 60, energy 0x0000, RR 512 (=> 0.5 s).
        let d = HeartRateMeasurement(Data([0x18, 0x3C, 0x00, 0x00, 0x00, 0x02]))
        #expect(d?.heartRateBpm == 60)
        #expect(d?.rrIntervals == [0.5])
    }

    @Test func rejectsTooShort() {
        #expect(HeartRateMeasurement(Data([0x00])) == nil)
    }
}

@Suite("Cycling power decode")
struct CyclingPowerMeasurementTests {
    @Test func decodesInstantaneousPower() {
        // flags 0x0000, power 250 (0x00FA) LE.
        let d = CyclingPowerMeasurement(Data([0x00, 0x00, 0xFA, 0x00]))
        #expect(d?.instantaneousPowerW == 250)
    }

    @Test func decodesNegativePower() {
        // power -5 (0xFFFB) — signed.
        let d = CyclingPowerMeasurement(Data([0x00, 0x00, 0xFB, 0xFF]))
        #expect(d?.instantaneousPowerW == -5)
    }

    @Test func rejectsTooShort() {
        #expect(CyclingPowerMeasurement(Data([0x00, 0x00, 0xFA])) == nil)
    }
}

@Suite("HR zones (LTHR)")
struct HRZoneTests {
    let engine = HRZoneEngine(lthr: 160)

    @Test func z2BandFromLTHR() {
        // Z2 = 85–89% of 160 => 136…142.
        #expect(engine.bpmRange(for: .z2Endurance) == 136...142)
    }

    @Test func classifyHR() {
        #expect(engine.zone(forHR: 120) == .z1Recovery)   // 75% LTHR
        #expect(engine.zone(forHR: 140) == .z2Endurance)  // ~88%
        #expect(engine.zone(forHR: 175) == .z5VO2Max)     // >105%
    }

    @Test func z1StartsAtZero() {
        #expect(engine.bpmRange(for: .z1Recovery).lowerBound == 0)
    }
}

@Suite("HR ride summary")
struct HRRideSummaryTests {
    private func recording(hrs: [Int], lthrForZone: Int = 160) -> RideRecording {
        let samples = hrs.enumerated().map {
            RideSample(secondsFromStart: $0.offset, powerW: 130, heartRateBpm: $0.element)
        }
        return RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
    }

    @Test func timeInHRZoneCountsInBandSeconds() {
        // LTHR 160 → HR Z2 band 136…142. 140 in-band; 120 (Z1) & 150 (Z4) out.
        let rec = recording(hrs: [120, 140, 140, 140, 150])
        #expect(rec.timeInHRZone(.z2Endurance, lthr: 160) == 3)
        #expect(abs(rec.timeInHRZoneFraction(.z2Endurance, lthr: 160) - 0.6) < 0.0001)
    }

    @Test func averageHeartRate() {
        let rec = recording(hrs: [130, 140, 150])
        #expect(rec.averageHeartRate == 140)
    }

    @Test func averageHeartRateZeroWhenNoHR() {
        let samples = [RideSample(secondsFromStart: 0, powerW: 130)]
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        #expect(rec.averageHeartRate == 0)
    }

    @Test func maxHeartRate() {
        let rec = recording(hrs: [130, 155, 140])
        #expect(rec.maxHeartRate == 155)
    }

    @Test func maxHeartRateZeroWhenNoHR() {
        let samples = [RideSample(secondsFromStart: 0, powerW: 130)]
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        #expect(rec.maxHeartRate == 0)
    }
}
