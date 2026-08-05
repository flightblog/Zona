import Foundation
import Testing
@testable import ZonaKit

@Suite("TCX export")
struct TCXExportTests {
    // 2026-07-01T07:30:00Z
    private var start: Date {
        let c = DateComponents(timeZone: TimeZone(identifier: "UTC"),
                               year: 2026, month: 7, day: 1, hour: 7, minute: 30, second: 0)
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func sample(_ s: Int, hr: Int? = nil, w: Int? = nil,
                        cad: Int? = nil, kph: Double? = nil) -> TCXSample {
        TCXSample(secondsFromStart: s, powerW: w, cadenceRpm: cad, speedKph: kph, heartRateBpm: hr)
    }

    @Test func producesWellFormedXML() throws {
        let tcx = TCXExporter.makeTCX(start: start, samples: [
            sample(0, hr: 130, w: 150, cad: 85),
            sample(1, hr: 132, w: 148, cad: 86)
        ])
        let parser = XMLParser(data: Data(tcx.utf8))
        #expect(parser.parse() == true)   // valid XML, no parse error
    }

    @Test func trackpointCountMatchesSamples() {
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, hr: 120), sample(1, hr: 121), sample(2, hr: 122)])
        let count = tcx.components(separatedBy: "<Trackpoint>").count - 1
        #expect(count == 3)
    }

    @Test func includesZonaCreatorAndAuthor() {
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, hr: 120)])
        // The activity Creator (Strava "recorded with") and document Author both
        // name the app, and the file still parses as valid XML.
        #expect(tcx.contains("<Creator xsi:type=\"Device_t\">"))
        #expect(tcx.contains("<Author xsi:type=\"Application_t\">"))
        #expect(tcx.contains("<Name>Zona</Name>"))
        #expect(XMLParser(data: Data(tcx.utf8)).parse())
    }

    @Test func firstTrackpointTimeIsStart() {
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, hr: 120)])
        #expect(tcx.contains("<Time>2026-07-01T07:30:00Z</Time>"))
    }

    @Test func timestampIsStartPlusOffset() {
        // offset 90s → 07:31:30Z
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(90, hr: 120)])
        #expect(tcx.contains("<Time>2026-07-01T07:31:30Z</Time>"))
    }

    @Test func rendersHRWattsCadence() {
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, hr: 145, w: 210, cad: 92)])
        #expect(tcx.contains("<HeartRateBpm><Value>145</Value></HeartRateBpm>"))
        #expect(tcx.contains("<ns3:Watts>210</ns3:Watts>"))
        #expect(tcx.contains("<Cadence>92</Cadence>"))
    }

    @Test func omitsNilFields() {
        // Only HR present → no Watts/Cadence/Extensions block.
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, hr: 130)])
        #expect(tcx.contains("<HeartRateBpm>"))
        #expect(!tcx.contains("<ns3:Watts>"))
        #expect(!tcx.contains("<Cadence>"))
        #expect(!tcx.contains("<Extensions>"))
    }

    // MARK: - Which power channel the file exports

    /// A ride whose every sample carries leg power exports the crank meter's
    /// watts, not the trainer's — the whole point of the change.
    @Test func exportsLegPowerWhenMeterCoveredTheRide() {
        let samples = (0..<10).map {
            TCXSample(secondsFromStart: $0, powerW: 200, powerMeterW: 210)
        }
        let tcx = TCXExporter.makeTCX(start: start, samples: samples)
        #expect(tcx.contains("<ns3:Watts>210</ns3:Watts>"))
        #expect(!tcx.contains("<ns3:Watts>200</ns3:Watts>"))
    }

    /// A meterless ride still uploads with power — it falls back to the trainer
    /// rather than exporting a file with no watts at all.
    @Test func fallsBackToTrainerWhenNoMeterWasPaired() {
        let samples = (0..<10).map { TCXSample(secondsFromStart: $0, powerW: 200) }
        let tcx = TCXExporter.makeTCX(start: start, samples: samples)
        #expect(tcx.contains("<ns3:Watts>200</ns3:Watts>"))
        #expect(TCXPowerSource.resolve(samples: samples) == .trainer)
    }

    /// The coverage floor: a meter that dropped early covers too little of the
    /// ride to be its power track, so the whole file reverts to trainer watts
    /// rather than exporting mostly-absent power for Strava to interpolate.
    @Test func sparseMeterFallsBackToTrainerForWholeRide() {
        // Meter reported for 3 of 10 seconds (30%, well under the floor).
        let samples = (0..<10).map {
            TCXSample(secondsFromStart: $0, powerW: 200, powerMeterW: $0 < 3 ? 210 : nil)
        }
        #expect(TCXPowerSource.resolve(samples: samples) == .trainer)
        let tcx = TCXExporter.makeTCX(start: start, samples: samples)
        #expect(tcx.contains("<ns3:Watts>200</ns3:Watts>"))
        #expect(!tcx.contains("<ns3:Watts>210</ns3:Watts>"))
        // Every second exports power — the trainer channel has no gaps.
        #expect(tcx.components(separatedBy: "<ns3:Watts>").count - 1 == 10)
    }

    /// Coverage exactly at the floor still qualifies (the comparison is `>=`),
    /// and one step below it does not — pinning the boundary so a later tweak
    /// to the constant can't silently move it.
    @Test func coverageFloorBoundaryIsInclusive() {
        func samples(covered: Int) -> [TCXSample] {
            (0..<10).map {
                TCXSample(secondsFromStart: $0, powerW: 200,
                          powerMeterW: $0 < covered ? 210 : nil)
            }
        }
        #expect(TCXPowerSource.minimumCoverage == 0.8)
        #expect(TCXPowerSource.resolve(samples: samples(covered: 8)) == .powerMeter)
        #expect(TCXPowerSource.resolve(samples: samples(covered: 7)) == .trainer)
    }

    /// A coast inside an otherwise well-covered metered ride omits `<ns3:Watts>`
    /// for that second rather than banking a fabricated 0 W. The crank meter
    /// goes quiet on a coast instead of sending a zero frame.
    @Test func gapInLegPowerOmitsWattsRatherThanExportingZero() {
        // 9 of 10 seconds covered (90%, over the floor); second 5 is a coast.
        let samples = (0..<10).map {
            TCXSample(secondsFromStart: $0, powerW: 200, powerMeterW: $0 == 5 ? nil : 210)
        }
        #expect(TCXPowerSource.resolve(samples: samples) == .powerMeter)
        let tcx = TCXExporter.makeTCX(start: start, samples: samples)
        #expect(!tcx.contains("<ns3:Watts>0</ns3:Watts>"))
        // The gap second falls back to no power at all, not to the trainer's
        // reading for that second — one calibration scale per file.
        #expect(!tcx.contains("<ns3:Watts>200</ns3:Watts>"))
        #expect(tcx.components(separatedBy: "<ns3:Watts>").count - 1 == 9)
    }

    /// A gap second with no speed either drops its whole extension block, the
    /// same way a trainer-sourced ride with no power does.
    @Test func gapWithNoSpeedOmitsExtensionsBlock() {
        let samples = [
            TCXSample(secondsFromStart: 0, powerW: 200, powerMeterW: 210),
            TCXSample(secondsFromStart: 1, powerW: 200, powerMeterW: 215),
            TCXSample(secondsFromStart: 2, powerW: 200, powerMeterW: nil),
        ]
        // 2 of 3 covered is 66%, under the floor — force the metered path by
        // checking the source directly on a well-covered ride instead.
        #expect(TCXPowerSource.resolve(samples: samples) == .trainer)
        let covered = (0..<10).map {
            TCXSample(secondsFromStart: $0, powerMeterW: $0 == 9 ? nil : 210)
        }
        let tcx = TCXExporter.makeTCX(start: start, samples: covered)
        // The last trackpoint has neither speed nor leg power → no Extensions.
        let trackpoints = tcx.components(separatedBy: "<Trackpoint>")
        #expect(trackpoints.count == 11)
        #expect(!trackpoints[10].contains("<Extensions>"))
    }

    /// Cadence stays the trainer's on a leg-power export — crank cadence isn't
    /// recorded per sample, so the two channels legitimately mix in one file.
    @Test func cadenceStaysTrainerSourcedOnLegPowerExport() {
        let samples = (0..<10).map {
            TCXSample(secondsFromStart: $0, powerW: 200, cadenceRpm: 92, powerMeterW: 210)
        }
        let tcx = TCXExporter.makeTCX(start: start, samples: samples)
        #expect(tcx.contains("<Cadence>92</Cadence>"))
        #expect(tcx.contains("<ns3:Watts>210</ns3:Watts>"))
    }

    /// An empty ride resolves to the trainer rather than dividing by zero.
    @Test func emptyRideResolvesToTrainer() {
        #expect(TCXPowerSource.resolve(samples: []) == .trainer)
    }

    @Test func convertsSpeedKphToMetersPerSecond() {
        // 36 km/h = 10.000 m/s
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, kph: 36.0)])
        #expect(tcx.contains("<ns3:Speed>10.000</ns3:Speed>"))
    }

    @Test func totalTimeSecondsPrefersRecordedDuration() {
        // The last sample only reaches second 2 (a dropped notification right
        // before the rider stopped), but the ride actually ran 9s — the
        // recorded duration should win so Strava's import matches Zona.
        let tcx = TCXExporter.makeTCX(start: start,
                                      samples: [sample(0), sample(1), sample(2)],
                                      durationSeconds: 9)
        #expect(tcx.contains("<TotalTimeSeconds>9</TotalTimeSeconds>"))
    }

    /// 0 is the "no recorded duration" sentinel (also `makeTCX`'s default), so
    /// this falls back to the last-sample derivation rather than writing 0.
    @Test func totalTimeSecondsFallsBackWhenDurationIsZero() {
        let tcx = TCXExporter.makeTCX(start: start,
                                      samples: [sample(0), sample(1), sample(2)],
                                      durationSeconds: 0)
        #expect(tcx.contains("<TotalTimeSeconds>3</TotalTimeSeconds>"))
    }

    @Test func sportAttributeAndActivityId() {
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, hr: 120)])
        #expect(tcx.contains("<Activity Sport=\"Biking\">"))
        #expect(tcx.contains("<Id>2026-07-01T07:30:00Z</Id>"))
    }

    @Test func sortsUnorderedSamples() {
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(2, hr: 3), sample(0, hr: 1), sample(1, hr: 2)])
        let firstIdx = tcx.range(of: "<Value>1</Value>")!.lowerBound
        let lastIdx = tcx.range(of: "<Value>3</Value>")!.lowerBound
        #expect(firstIdx < lastIdx)   // sample 0 rendered before sample 2
    }

    @Test func lapDistanceIntegratesSpeed() {
        // 36 km/h = 10 m/s across 0,1,2s → two 1s gaps → 20.000 m lap total.
        let tcx = TCXExporter.makeTCX(start: start, samples: [
            sample(0, kph: 36), sample(1, kph: 36), sample(2, kph: 36)
        ])
        #expect(tcx.contains("<DistanceMeters>20.000</DistanceMeters>"))
        #expect(XMLParser(data: Data(tcx.utf8)).parse())
    }

    @Test func trackpointsCarryCumulativeDistance() {
        // Running totals 10, 20, 20 (last sample has no next interval).
        let tcx = TCXExporter.makeTCX(start: start, samples: [
            sample(0, kph: 36), sample(1, kph: 36), sample(2, kph: 36)
        ])
        #expect(tcx.contains("<DistanceMeters>10.000</DistanceMeters>"))
        // The lap total (also 20.000) and the last two trackpoints coincide.
        let occurrences = tcx.components(separatedBy: "<DistanceMeters>20.000</DistanceMeters>").count - 1
        #expect(occurrences >= 2)   // lap total + at least one trackpoint
    }

    @Test func noDistanceWhenNoSpeed() {
        // Power/HR-only ride → lap distance 0, no per-trackpoint DistanceMeters.
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, hr: 120, w: 150), sample(1, hr: 121, w: 151)])
        #expect(tcx.contains("<DistanceMeters>0.000</DistanceMeters>"))   // lap total
        // Only the single lap-level element; none inside Trackpoints.
        let count = tcx.components(separatedBy: "<DistanceMeters>").count - 1
        #expect(count == 1)
    }
}
