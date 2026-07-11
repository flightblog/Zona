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

/// In-memory `SensorMemory` for tests: records preferred/remembered per kind.
final class FakeSensorMemory: SensorMemory, @unchecked Sendable {
    var remembered: [SensorKind: UUID] = [:]
    var preferred: [SensorKind: UUID] = [:]

    func rememberedIdentifier(for kind: SensorKind) -> UUID? { remembered[kind] }
    func remember(_ identifier: UUID, for kind: SensorKind) { remembered[kind] = identifier }
    func preferredIdentifier(for kind: SensorKind) -> UUID? { preferred[kind] }
    func setPreferred(_ identifier: UUID?, for kind: SensorKind) { preferred[kind] = identifier }
}

@Suite("Preferred device gating")
struct PreferredGatingTests {
    let whoop = UUID()
    let garmin = UUID()

    @Test func attachesAnyWhenNoPreference() {
        // No pin: first-to-connect — any candidate qualifies (original behavior).
        #expect(shouldAttach(candidate: whoop, forKind: .heartRate, preferred: nil))
        #expect(shouldAttach(candidate: garmin, forKind: .heartRate, preferred: nil))
    }

    @Test func attachesOnlyPreferredWhenPinned() {
        // Pinned WHOOP: the Garmin strap must be ignored for the HR slot.
        #expect(shouldAttach(candidate: whoop, forKind: .heartRate, preferred: whoop))
        #expect(!shouldAttach(candidate: garmin, forKind: .heartRate, preferred: whoop))
    }

    @Test func memoryRoundTripsAndClears() {
        let mem = FakeSensorMemory()
        #expect(mem.preferredIdentifier(for: .heartRate) == nil)
        mem.setPreferred(whoop, for: .heartRate)
        #expect(mem.preferredIdentifier(for: .heartRate) == whoop)
        // Clearing restores first-to-connect.
        mem.setPreferred(nil, for: .heartRate)
        #expect(mem.preferredIdentifier(for: .heartRate) == nil)
    }

    @Test func preferredIsIndependentOfRemembered() {
        // Preferred (explicit choice) and remembered (last connected) are
        // separate; pinning one kind's device doesn't affect another kind.
        let mem = FakeSensorMemory()
        mem.remember(garmin, for: .heartRate)
        mem.setPreferred(whoop, for: .heartRate)
        #expect(mem.rememberedIdentifier(for: .heartRate) == garmin)
        #expect(mem.preferredIdentifier(for: .heartRate) == whoop)
        #expect(mem.preferredIdentifier(for: .trainer) == nil)
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

    @Test func noOptionalFieldsWhenFlagsClear() {
        let d = CyclingPowerMeasurement(Data([0x00, 0x00, 0xFA, 0x00]))
        #expect(d?.cumulativeCrankRevolutions == nil)
        #expect(d?.lastCrankEventTime == nil)
    }

    @Test func decodesCrankRevolutions() {
        // flags 0x0020 (crank rev present), power 200, revs 0x0064 = 100,
        // event time 0x0400 = 1024 (= 1.0 s).
        let d = CyclingPowerMeasurement(
            Data([0x20, 0x00, 0xC8, 0x00, 0x64, 0x00, 0x00, 0x04]))
        #expect(d?.cumulativeCrankRevolutions == 100)
        #expect(d?.lastCrankEventTime == 1024)
    }

    /// The crank field sits AFTER balance + torque; decoding it correctly proves
    /// the walker skips the earlier present (but unused) fields by the right byte
    /// widths.
    @Test func reachesCrankFieldPastBalanceAndTorque() {
        // flags 0x0025 = balance(0x01) + torque(0x04) + crank(0x20).
        // power 200 | balance 0x68 (skipped) | torque 0x1234 (skipped) | revs 50 | time 512.
        let d = CyclingPowerMeasurement(
            Data([0x25, 0x00, 0xC8, 0x00, 0x68, 0x34, 0x12, 0x32, 0x00, 0x00, 0x02]))
        #expect(d?.cumulativeCrankRevolutions == 50)
        #expect(d?.lastCrankEventTime == 512)
    }

    /// A flag claims crank data but the packet is truncated — the reader must not
    /// crash or read past the end; it leaves the field nil.
    @Test func truncatedOptionalFieldStaysNil() {
        // flags claim crank present but only power bytes follow.
        let d = CyclingPowerMeasurement(Data([0x20, 0x00, 0xC8, 0x00]))
        #expect(d?.instantaneousPowerW == 200)
        #expect(d?.cumulativeCrankRevolutions == nil)
    }
}

@Suite("Power meter isolation")
@MainActor
struct PowerMeterIsolationTests {
    /// A power-meter reading must land in `powerMeterW` and leave the trainer's
    /// `powerW` untouched, so the meter can't skew ERG/recording/export.
    @Test func meterReadingDoesNotTouchTrainerPower() {
        let hub = SensorHub()
        hub.applyForTesting(SensorReading(powerW: 200))       // trainer
        hub.applyForTesting(SensorReading(powerMeterW: 187))  // Quarq
        #expect(hub.metrics.powerW == 200)
        #expect(hub.metrics.powerMeterW == 187)
    }

    /// The trainer keeps updating `powerW` independently of the meter.
    @Test func trainerAndMeterTrackSeparately() {
        let hub = SensorHub()
        hub.applyForTesting(SensorReading(powerMeterW: 190))
        hub.applyForTesting(SensorReading(powerW: 205))
        hub.applyForTesting(SensorReading(powerMeterW: 195))
        #expect(hub.metrics.powerW == 205)
        #expect(hub.metrics.powerMeterW == 195)
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

    @Test func secondsPerZoneBucketsEachReadingOnce() {
        // Three Z1 (120), two Z2 (140), one Z5 (175); each reading = 1 second.
        let bpms = [120, 120, 120, 140, 140, 175]
        let buckets = engine.secondsPerZone(bpms: bpms)
        #expect(buckets == [HRZone.z1Recovery.rawValue: 3,
                            HRZone.z2Endurance.rawValue: 2,
                            HRZone.z5VO2Max.rawValue: 1])
        // Total time is conserved — no reading double-counted at a boundary.
        #expect(buckets.values.reduce(0, +) == bpms.count)
    }

    @Test func secondsPerZoneEmptyForNoReadings() {
        #expect(engine.secondsPerZone(bpms: []).isEmpty)
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

    @Test func hrvSummaryConcatenatesPerSecondIntervals() {
        // Spread 30 alternating R-R intervals across 15 seconds (2 beats each),
        // matching how the recorder buckets them. The summary flattens them in
        // time order → RMSSD 40 ms (constant 40 ms successive difference).
        let samples = (0..<15).map {
            RideSample(secondsFromStart: $0, heartRateBpm: 73,
                       rrIntervalsSec: [0.800, 0.840])
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        #expect(rec.hrvRMSSDms == 40)
        #expect(rec.summary().hrvRMSSDms == 40)
    }

    @Test func hrvSummaryNilWhenNoRR() {
        // HR present but no strap R-R (e.g. a sensor that omits it) → nil, so the
        // UI shows "—" rather than a fabricated 0.
        let rec = recording(hrs: [130, 140, 150])
        #expect(rec.hrvRMSSDms == nil)
        #expect(rec.summary().hrvRMSSDms == nil)
    }
}
