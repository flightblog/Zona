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
}

@Suite("Ride recorder")
@MainActor
struct RideRecorderTests {
    /// Several ingests within the same second collapse to one sample; last
    /// value per field wins.
    @Test func collapsesToOneHz() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        // Three snapshots inside second 0, two inside second 1.
        rec.ingest(RideMetrics(powerW: 100), at: t0 + .milliseconds(100))
        rec.ingest(RideMetrics(powerW: 120), at: t0 + .milliseconds(400))
        rec.ingest(RideMetrics(powerW: 130, cadenceRpm: 85), at: t0 + .milliseconds(900))
        rec.ingest(RideMetrics(powerW: 140), at: t0 + .milliseconds(1200))
        rec.ingest(RideMetrics(powerW: 150), at: t0 + .milliseconds(1800))

        let recording = rec.finish()
        #expect(recording.samples.count == 2)
        #expect(recording.samples[0].secondsFromStart == 0)
        #expect(recording.samples[0].powerW == 130)   // last write in second 0
        #expect(recording.samples[0].cadenceRpm == 85)
        #expect(recording.samples[1].powerW == 150)    // last write in second 1
    }

    @Test func elapsedTracksSeconds() {
        let rec = RideRecorder()
        let t0 = ContinuousClock.now
        rec.start(ftp: 200, zone: .z2Endurance, clock: t0)
        rec.ingest(RideMetrics(powerW: 100), at: t0 + .seconds(4) + .milliseconds(500))
        #expect(rec.elapsedSeconds == 5)  // seconds 0…4 → 5 elapsed
    }
}

@Suite("Ride summary")
struct RideSummaryTests {
    /// Build a recording of `count` samples each at `watts`.
    private func steady(_ watts: Int, count: Int, ftp: Int = 200,
                        zone: PowerZone = .z2Endurance) -> RideRecording {
        let samples = (0..<count).map { RideSample(secondsFromStart: $0, powerW: watts) }
        return RideRecording(ftp: ftp, zone: zone, startedAt: Date(), samples: samples)
    }

    @Test func averageAndMaxAndDuration() {
        let samples = [100, 200, 300].enumerated().map {
            RideSample(secondsFromStart: $0.offset, powerW: $0.element)
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        let s = rec.summary()
        #expect(s.durationSeconds == 3)
        #expect(s.averagePowerW == 200)
        #expect(s.maxPowerW == 300)
    }

    @Test func normalizedEqualsAverageForSteadyPower() {
        // Constant power → NP == average power, even across the 30s window.
        let rec = steady(130, count: 120)
        let s = rec.summary()
        #expect(s.averagePowerW == 130)
        #expect(s.normalizedPowerW == 130)
    }

    @Test func normalizedFallsBackToMeanUnder30Samples() {
        #expect(RideRecording.normalizedPower([100, 200]) == 150)
    }

    @Test func timeInZoneCountsInBandSeconds() {
        // FTP 200 → Z2 band 110…150. 130 is in-band, 90 (Z1) and 200 (Z4) are not.
        let powers = [90, 130, 130, 130, 200]
        let samples = powers.enumerated().map {
            RideSample(secondsFromStart: $0.offset, powerW: $0.element)
        }
        let rec = RideRecording(ftp: 200, zone: .z2Endurance, startedAt: Date(), samples: samples)
        #expect(rec.timeInZone() == 3)
        #expect(rec.summary().timeInZoneSeconds == 3)
        #expect(abs(rec.timeInZoneFraction - 0.6) < 0.0001)
    }
}
