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

@Suite("Kind resolution from exposed services")
struct ResolveKindTests {
    let kickr = UUID()
    let quarq = UUID()
    let garmin = UUID()

    /// A Kickr-like trainer that also implements the legacy Cycling Power
    /// Service (for power-only head units) must resolve to `.trainer`, not
    /// `.powerMeter` — reproducing the bug where the trainer stole the
    /// power-meter slot and a real SRAM/Quarq meter never got to connect.
    @Test func trainerWinsOverPowerMeterWhenBothServicesPresent() {
        let kind = resolveKind(candidate: kickr,
                               exposedServices: [SensorKind.trainer.serviceUUID,
                                                 SensorKind.powerMeter.serviceUUID],
                               eligibleKinds: [.trainer, .heartRate, .powerMeter],
                               preferred: { _ in nil })
        #expect(kind == .trainer)
    }

    /// Once the trainer has claimed `.trainer`, a real standalone power meter
    /// (only the Cycling Power service) must still resolve to `.powerMeter`.
    @Test func realPowerMeterResolvesOnceTrainerSlotIsTaken() {
        let kind = resolveKind(candidate: quarq,
                               exposedServices: [SensorKind.powerMeter.serviceUUID],
                               eligibleKinds: [.heartRate, .powerMeter],   // .trainer already filled
                               preferred: { _ in nil })
        #expect(kind == .powerMeter)
    }

    /// A device exposing only the HR service resolves to `.heartRate`
    /// regardless of ordering.
    @Test func heartRateResolvesNormally() {
        let kind = resolveKind(candidate: garmin,
                               exposedServices: [SensorKind.heartRate.serviceUUID],
                               eligibleKinds: [.trainer, .heartRate, .powerMeter],
                               preferred: { _ in nil })
        #expect(kind == .heartRate)
    }

    /// No exposed service matches any eligible kind: no resolution.
    @Test func noMatchResolvesToNil() {
        let kind = resolveKind(candidate: garmin,
                               exposedServices: [SensorKind.heartRate.serviceUUID],
                               eligibleKinds: [.trainer, .powerMeter],
                               preferred: { _ in nil })
        #expect(kind == nil)
    }

    /// A pinned preferred device for `.powerMeter` still gates correctly even
    /// when the candidate also happens to expose the trainer's service.
    @Test func preferredGatingStillAppliesWhenTrainerServiceAlsoPresent() {
        let kind = resolveKind(candidate: kickr,
                               exposedServices: [SensorKind.trainer.serviceUUID,
                                                 SensorKind.powerMeter.serviceUUID],
                               eligibleKinds: [.powerMeter],   // .trainer already filled elsewhere
                               preferred: { $0 == .powerMeter ? quarq : nil })
        // Kickr isn't the pinned power meter, so it must not be attached as one.
        #expect(kind == nil)
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
    /// `powerW` untouched, so the meter can't skew ERG or the zone math. The
    /// export does read this channel, but by choosing between the two per file
    /// (`TCXPowerSource`) — which only works while they stay unmerged here.
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

    /// A meter that goes quiet (the rider coasts) must not leave its last watts
    /// frozen in `metrics`. It sends *nothing* rather than a 0 W frame, unlike the
    /// trainer's FTMS stream — and since the recorder re-ingests metrics every
    /// second, a stuck value would bank fabricated leg power for the rest of the
    /// ride. The trainer's own power is unaffected and keeps flowing.
    @Test func stalePowerMeterReadingExpires() {
        let hub = SensorHub()
        let t0 = ContinuousClock.now
        hub.applyForTesting(SensorReading(powerMeterW: 250, powerMeterCadenceRpm: 90), at: t0)
        #expect(hub.metrics.powerMeterW == 250)

        // Rider stops pedalling: the trainer keeps streaming (0 W on the flywheel),
        // the Quarq says nothing at all. Past the freshness window its reading is
        // dropped rather than held.
        hub.applyForTesting(SensorReading(powerW: 0), at: t0 + .seconds(4))
        #expect(hub.metrics.powerMeterW == nil)
        #expect(hub.metrics.powerMeterCadenceRpm == nil)
        #expect(hub.metrics.powerW == 0)   // trainer untouched
    }

    /// Normal pedalling (a meter notifying at ~1 Hz) must never flicker to nil —
    /// the freshness window sits comfortably above the notify rate.
    @Test func steadyPowerMeterReadingsStayFresh() {
        let hub = SensorHub()
        let t0 = ContinuousClock.now
        hub.applyForTesting(SensorReading(powerMeterW: 200), at: t0)
        hub.applyForTesting(SensorReading(powerW: 195), at: t0 + .seconds(1))
        #expect(hub.metrics.powerMeterW == 200)   // 1 s old: still fresh
        hub.applyForTesting(SensorReading(powerMeterW: 202), at: t0 + .seconds(2))
        hub.applyForTesting(SensorReading(powerW: 196), at: t0 + .seconds(3))
        #expect(hub.metrics.powerMeterW == 202)   // refreshed by the new reading
    }

    /// The reading expires *at* the freshness window, not a second past it. The
    /// sweep only runs when some sensor reports, so an exclusive `>` comparison
    /// let the value survive to the next tick — a 3 s window banking 4 s of
    /// coasted watts. Pin the boundary: still fresh just under, gone exactly at.
    @Test func powerMeterExpiresAtTheWindowNotAfterIt() {
        let hub = SensorHub()
        let t0 = ContinuousClock.now
        hub.applyForTesting(SensorReading(powerMeterW: 250), at: t0)

        hub.applyForTesting(SensorReading(powerW: 0), at: t0 + .milliseconds(2_999))
        #expect(hub.metrics.powerMeterW == 250)   // just inside the window

        hub.applyForTesting(SensorReading(powerW: 0), at: t0 + .seconds(3))
        #expect(hub.metrics.powerMeterW == nil)   // exactly at it: stale
    }

    /// Expiry must not depend on *other* sensors still talking. The sweep inside
    /// `apply` only runs when some sensor reports, so if the trainer drops or
    /// stalls too, nothing would clear the meter and the 1 Hz recorder would bank
    /// its last wattage forever. An explicit sweep — driven by the ride screen's
    /// own clock — expires it with zero sensor traffic.
    @Test func sweepExpiresPowerMeterWithNoOtherSensorTraffic() {
        let hub = SensorHub()
        let t0 = ContinuousClock.now
        hub.applyForTesting(SensorReading(powerMeterW: 250, powerMeterCadenceRpm: 90), at: t0)
        #expect(hub.metrics.powerMeterW == 250)

        // Nothing reports — not the meter, not the trainer, nothing.
        hub.sweepStalePowerMeter(at: t0 + .seconds(1))
        #expect(hub.metrics.powerMeterW == 250)   // still inside the window

        hub.sweepStalePowerMeter(at: t0 + .seconds(3))
        #expect(hub.metrics.powerMeterW == nil)   // expired on the sweep's own clock
        #expect(hub.metrics.powerMeterCadenceRpm == nil)
    }

    /// The sweep republishes metrics only when it actually expires something —
    /// a no-op sweep (no meter, or a still-fresh one) mustn't spam `onMetricsChange`
    /// and churn SwiftUI every second.
    @Test func sweepOnlyPublishesWhenItClears() {
        let hub = SensorHub()
        var publishes = 0
        hub.onMetricsChange = { _ in publishes += 1 }
        let t0 = ContinuousClock.now

        hub.sweepStalePowerMeter(at: t0)          // no meter ever seen
        #expect(publishes == 0)

        hub.applyForTesting(SensorReading(powerMeterW: 250), at: t0)
        publishes = 0
        hub.sweepStalePowerMeter(at: t0 + .seconds(1))   // still fresh
        #expect(publishes == 0)

        hub.sweepStalePowerMeter(at: t0 + .seconds(3))   // expires
        #expect(publishes == 1)
        hub.sweepStalePowerMeter(at: t0 + .seconds(4))   // already gone: no-op
        #expect(publishes == 1)
    }

    /// A meter that drops mid-ride clears immediately, without waiting for another
    /// sensor's reading to trigger the freshness check.
    @Test func disconnectedPowerMeterClearsItsValues() {
        let hub = SensorHub()
        hub.applyForTesting(SensorReading(powerW: 200))
        hub.applyForTesting(SensorReading(powerMeterW: 210, powerMeterCadenceRpm: 88))
        #expect(hub.metrics.powerMeterW == 210)

        hub.setStateForTesting(.disconnected, for: .powerMeter)
        #expect(hub.metrics.powerMeterW == nil)
        #expect(hub.metrics.powerMeterCadenceRpm == nil)
        #expect(hub.metrics.powerW == 200)   // trainer untouched
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
        #expect(rec.timeInHRZone(.z2Endurance, zoning: .lthr(160)) == 3)
        #expect(abs(rec.timeInHRZoneFraction(.z2Endurance, zoning: .lthr(160)) - 0.6) < 0.0001)
    }

    @Test func timeInHRZoneFractionDividesByWallClockDuration() {
        // 3 of 5 in-band samples, but the ride actually lasted 10 s — seconds
        // with no sample at all (dropped notifications) still count toward the
        // denominator, so the fraction is 3/10, not 3/5. Using samples.count
        // would overstate it as 0.6.
        let samples = [120, 140, 140, 140, 150].enumerated().map {
            RideSample(secondsFromStart: $0.offset, powerW: 130, heartRateBpm: $0.element)
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(),
                                samples: samples, durationSeconds: 10)
        #expect(rec.timeInHRZone(.z2Endurance, zoning: .lthr(160)) == 3)
        #expect(abs(rec.timeInHRZoneFraction(.z2Endurance, zoning: .lthr(160)) - 0.3) < 0.0001)
    }

    @Test func timeInHRZoneScoresAgainstWhoopBandsWhenZoned() {
        // Same HR samples, scored under WHOOP's HRR bands instead of LTHR. With
        // max 190 / resting 50 the reserve is 140, so Z2 (60–70% HRR) is 134…148:
        // 140 and 145 are in-band, and 150 — which LTHR 160 would call Z4 — now
        // falls outside Z2's ceiling too, while 120 stays below the floor.
        let rec = recording(hrs: [120, 140, 145, 150, 190])
        let whoop = RideHRZoning.whoopHRR(maxHR: 190, restingHR: 50, lthr: 160)
        #expect(whoop.bpmRange(for: .z2Endurance) == 134...148)
        #expect(rec.timeInHRZone(.z2Endurance, zoning: whoop) == 2)

        // The same recording under LTHR 160 counts only 140 (band 136…142), so the
        // two models genuinely disagree — which is the whole reason a ride has to
        // remember which one it was ridden against.
        #expect(rec.timeInHRZone(.z2Endurance, zoning: .lthr(160)) == 1)
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
