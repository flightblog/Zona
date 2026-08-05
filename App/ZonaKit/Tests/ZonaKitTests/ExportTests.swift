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

    /// `resolve` is a pure function of the samples: repeated calls return the
    /// same answer, and it holds no state that a second call could disturb.
    ///
    /// This is what makes the caller's compute-once rule *safe*. The app
    /// resolves the source once per ride into `@State`
    /// (`RideSummaryView.task(id:)`) rather than from a view body, because
    /// `Ride.tcxPowerSource` sorts and materializes an entire `[TCXSample]` from
    /// SwiftData on every read — the same long-ride stall the chart's
    /// downsampling fixed. Caching a value is only correct if recomputing it
    /// would agree; this pins that. It can't reach the app-target call site
    /// itself (no app test target — CI runs ZonaKit only), so a body-level
    /// `ride.tcxPowerSource` stays a review-time catch.
    @Test func resolveIsPureAcrossRepeatedCalls() {
        let samples = (0..<10).map {
            TCXSample(secondsFromStart: $0, powerW: 200,
                      powerMeterW: $0 < 9 ? 210 : nil)   // 90%, over the floor
        }
        let first = TCXPowerSource.resolve(samples: samples)
        #expect(first == .powerMeter)
        // Resolving again — as a re-render would — must not drift.
        for _ in 0..<5 {
            #expect(TCXPowerSource.resolve(samples: samples) == first)
        }
        // And the exported file agrees with the cached answer, so a caption
        // driven by the stored value can't contradict the bytes uploaded.
        let tcx = TCXExporter.makeTCX(start: start, samples: samples)
        #expect(tcx.contains("<ns3:Watts>210</ns3:Watts>"))
    }

    /// Coverage is a property of the whole sample set, not of its order, so the
    /// caller may sort before or after resolving without changing the file's
    /// power source. `Ride.tcxPowerSource` and `tcxString()` both build from the
    /// same sorted `tcxSamples`; this pins that they can't disagree if that
    /// bridging is ever reordered or memoized.
    @Test func resolveIgnoresSampleOrder() {
        let ordered = (0..<10).map {
            TCXSample(secondsFromStart: $0, powerW: 200,
                      powerMeterW: $0 < 8 ? 210 : nil)   // exactly at the floor
        }
        #expect(TCXPowerSource.resolve(samples: ordered) == .powerMeter)
        #expect(TCXPowerSource.resolve(samples: ordered.reversed()) == .powerMeter)
        #expect(TCXPowerSource.resolve(samples: ordered.shuffled()) == .powerMeter)
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

    // MARK: - Calories

    /// The core arithmetic, hand-checked: 200 W held across 3600 one-second gaps
    /// is 720 kJ of work, which at 24% gross efficiency is 720 / 4.184 / 0.24 ≈
    /// 717 kcal. Note how close that lands to the raw kJ figure — the near-1:1
    /// kJ↔kcal coincidence the estimate leans on.
    @Test func caloriesIntegrateWattsOverTime() {
        // 3601 samples → 3600 one-second intervals at 200 W.
        let samples = (0...3600).map { TCXSample(secondsFromStart: $0, powerW: 200) }
        let kcal = TCXEnergy.kilocalories(samples: samples, source: .trainer)
        #expect(kcal == 717)
        // 720 kJ of mechanical work, for reference — within 0.5% of the kcal.
        #expect(abs(Double(kcal) - 720) / 720 < 0.005)
    }

    /// Calories come from whichever channel the file exports, so a reader who
    /// derives kJ from the trackpoints lands where `<Calories>` already sits.
    /// A leg-power ride reads higher than the same ride scored on trainer watts —
    /// the drivetrain-loss gap, carried through consistently rather than mixed.
    @Test func caloriesUseTheExportedPowerChannel() {
        let samples = (0...3600).map {
            TCXSample(secondsFromStart: $0, powerW: 200, powerMeterW: 210)
        }
        #expect(TCXPowerSource.resolve(samples: samples) == .powerMeter)

        let legKcal = TCXEnergy.kilocalories(samples: samples, source: .powerMeter)
        let trainerKcal = TCXEnergy.kilocalories(samples: samples, source: .trainer)
        #expect(legKcal == 753)
        #expect(trainerKcal == 717)
        #expect(legKcal > trainerKcal)

        // The document uses the resolved channel, not the trainer's.
        let tcx = TCXExporter.makeTCX(start: start, samples: samples)
        #expect(tcx.contains("<Calories>753</Calories>"))
    }

    /// A sparse meter reverts the whole file to trainer watts — and the calorie
    /// total must revert with it, or the file would state energy for a channel it
    /// didn't export.
    @Test func caloriesFollowTheFallbackToTrainer() {
        // Meter covered 3 of 3601 samples, far under the floor.
        let samples = (0...3600).map {
            TCXSample(secondsFromStart: $0, powerW: 200, powerMeterW: $0 < 3 ? 210 : nil)
        }
        #expect(TCXPowerSource.resolve(samples: samples) == .trainer)
        let tcx = TCXExporter.makeTCX(start: start, samples: samples)
        #expect(tcx.contains("<Calories>717</Calories>"))
    }

    /// A coast contributes zero energy rather than being skipped or carried
    /// forward. Unlike a trackpoint's `<ns3:Watts>` — which omits the element
    /// rather than fabricating a 0 — an energy total spans every second it
    /// covers, and a quiet crank means no work was done.
    @Test func gapsInLegPowerContributeNoEnergyRatherThanCarryingForward() {
        // Full-coverage ride at 200 W: 3600 one-second intervals = 720 kJ.
        let steady = (0...3600).map { TCXSample(secondsFromStart: $0, powerMeterW: 200) }
        // The same ride with the last 600 seconds coasted — the meter went quiet
        // rather than sending 0 W frames. Still 83% covered, above the floor, so
        // this really does export as a leg-power file.
        let coasted = (0...3600).map {
            TCXSample(secondsFromStart: $0, powerMeterW: $0 < 3000 ? 200 : nil)
        }
        #expect(TCXPowerSource.resolve(samples: coasted) == .powerMeter)

        // Exact values, not a ratio: samples 0…2999 each open a one-second
        // interval at 200 W, so 3000 s × 200 W = 600 kJ → 598 kcal, against the
        // steady ride's 720 kJ → 717. A coast that carried the last-held 200 W
        // forward would score the full 717 instead.
        #expect(TCXEnergy.kilocalories(samples: steady, source: .powerMeter) == 717)
        #expect(TCXEnergy.kilocalories(samples: coasted, source: .powerMeter) == 598)
    }

    /// The gap rule stated directly, with no steady ride to compare against: a
    /// ride that is *only* coasting banks no energy at all. This is the one that
    /// fails outright if a nil ever starts inheriting the previous second's
    /// watts, however the carry-forward is spelled.
    @Test func anEntirelyCoastingMeterBanksNoEnergy() {
        // One real reading, then two minutes of silence. Only the first
        // interval did any work: 1 s × 300 W = 0.3 kJ, which rounds to 0 kcal.
        var samples = [TCXSample(secondsFromStart: 0, powerMeterW: 300),
                       TCXSample(secondsFromStart: 1, powerMeterW: nil)]
        samples += (2...120).map { TCXSample(secondsFromStart: $0, powerMeterW: nil) }
        #expect(TCXEnergy.kilocalories(samples: samples, source: .powerMeter) == 0)

        // Same shape at a wattage high enough to register, so the assertion
        // above isn't just rounding to 0 regardless: the single 1 s interval at
        // 30000 W is 30 kJ → 30 kcal, and the 119 silent seconds add nothing.
        var loud = [TCXSample(secondsFromStart: 0, powerMeterW: 30000)]
        loud += (1...120).map { TCXSample(secondsFromStart: $0, powerMeterW: nil) }
        #expect(TCXEnergy.kilocalories(samples: loud, source: .powerMeter) == 30)
    }

    /// A coast pays for its own duration: intervals are measured between
    /// *adjacent samples*, so a run of silent seconds can never be collapsed and
    /// charged to the reading on either side of it.
    ///
    /// (Note that treating a coasted second as 0 W and skipping it outright are
    /// arithmetically the same thing here, precisely because `dt` spans adjacent
    /// samples rather than adjacent *readings* — a zero term and an absent term
    /// both add nothing. The rule worth pinning is this one: the gap's duration
    /// never migrates onto a neighbouring reading's watts.)
    @Test func aCoastNeverChargesItsDurationToTheNextReading() {
        // 1 s at 1000 W, 98 s of silence, then a closing 1000 W sample. Only the
        // first second did work: 1 kJ → ~1 kcal. Were the silence collapsed, the
        // 1000 W reading would span all 99 s and bank ~99 kcal.
        var samples = [TCXSample(secondsFromStart: 0, powerMeterW: 1000)]
        samples += (1...98).map { TCXSample(secondsFromStart: $0, powerMeterW: nil) }
        samples.append(TCXSample(secondsFromStart: 99, powerMeterW: 1000))
        #expect(TCXEnergy.kilocalories(samples: samples, source: .powerMeter) == 1)

        // The same two real readings with the silence *absent* from the sample
        // list rather than nil-valued — a recorder that logged nothing at all
        // during the coast. Now the 0 s reading genuinely does span 99 s, and
        // the figure rises accordingly. This is the contrast the rule turns on.
        let sparse = [TCXSample(secondsFromStart: 0, powerMeterW: 1000),
                      TCXSample(secondsFromStart: 99, powerMeterW: 1000)]
        #expect(TCXEnergy.kilocalories(samples: sparse, source: .powerMeter) == 99)
    }

    /// Step integration, matching how the exporter integrates speed: watts are
    /// held over the gap to the *next* sample, so a dropped second is spanned by
    /// the reading before it rather than interpolated or dropped.
    @Test func caloriesHoldWattsAcrossASampleGap() {
        // 0s and 10s only: one 10-second interval at 360 W = 3.6 kJ.
        let gapped = [TCXSample(secondsFromStart: 0, powerW: 360),
                      TCXSample(secondsFromStart: 10, powerW: 360)]
        // The same 10 seconds sampled every second.
        let dense = (0...10).map { TCXSample(secondsFromStart: $0, powerW: 360) }
        #expect(TCXEnergy.kilocalories(samples: gapped, source: .trainer)
                == TCXEnergy.kilocalories(samples: dense, source: .trainer))
    }

    /// Which end of the interval supplies the watts, pinned with a step change so
    /// the two readings can't be confused. A 100 s interval at 1000 W followed by
    /// a final sample at 0 W integrates the *leading* reading — 100 kJ, ~100 kcal
    /// — not the trailing one, which would score 0.
    @Test func caloriesIntegrateTheLeadingSampleOfEachInterval() {
        let samples = [TCXSample(secondsFromStart: 0, powerW: 1000),
                       TCXSample(secondsFromStart: 100, powerW: 0)]
        #expect(TCXEnergy.kilocalories(samples: samples, source: .trainer) == 100)

        // Mirrored: leading 0 W then a high trailing reading banks nothing, since
        // the trailing sample closes the interval and opens none of its own.
        let mirrored = [TCXSample(secondsFromStart: 0, powerW: 0),
                        TCXSample(secondsFromStart: 100, powerW: 1000)]
        #expect(TCXEnergy.kilocalories(samples: mirrored, source: .trainer) == 0)
    }

    /// The trailing sample has no following interval, so a single-sample ride has
    /// no span to integrate and reports 0 rather than inventing a second's worth.
    @Test func caloriesAreZeroWithoutASpanToIntegrate() {
        #expect(TCXEnergy.kilocalories(samples: [], source: .trainer) == 0)
        #expect(TCXEnergy.kilocalories(
            samples: [TCXSample(secondsFromStart: 0, powerW: 250)], source: .trainer) == 0)
    }

    /// An HR-only ride has no watts on either channel, so there's no work to
    /// integrate — 0 is honest, and the element stays schema-valid.
    @Test func caloriesAreZeroOnAPowerlessRide() {
        let tcx = TCXExporter.makeTCX(start: start, samples: [sample(0, hr: 120), sample(1, hr: 121)])
        #expect(tcx.contains("<Calories>0</Calories>"))
        #expect(XMLParser(data: Data(tcx.utf8)).parse())
    }

    /// `kilocalories` is a pure function of its inputs and independent of sample
    /// order, the same property `resolve` carries — the exporter sorts before
    /// calling, but nothing should depend on that having happened.
    @Test func caloriesAreOrderIndependentAndRepeatable() {
        let samples = (0...600).map { TCXSample(secondsFromStart: $0, powerW: 150 + $0 % 40) }
        let inOrder = TCXEnergy.kilocalories(samples: samples, source: .trainer)
        #expect(TCXEnergy.kilocalories(samples: samples.reversed(), source: .trainer) == inOrder)
        #expect(TCXEnergy.kilocalories(samples: samples.shuffled(), source: .trainer) == inOrder)
        #expect(TCXEnergy.kilocalories(samples: samples, source: .trainer) == inOrder)
    }
}
