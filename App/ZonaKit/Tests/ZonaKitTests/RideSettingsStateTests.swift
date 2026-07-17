import Testing
@testable import ZonaKit

/// Covers the decision logic on `RideSettingsState` — the part that used to live
/// in the app target's `RideSettings` and could only be exercised by running the
/// app. The zoning *math* (`resolve`, `bpmRange`) is already covered by
/// `RideHRZoningTests`; these tests only pin how the settings type feeds it and
/// its own zone-sync / WHOOP-input behaviour.
struct RideSettingsStateTests {

    // MARK: syncHRZoneToHoldZone

    @Test func syncMirrorsHRZoneToHoldZoneByRawValue() {
        var state = RideSettingsState(zone: .z1Recovery, hrZone: .z4Threshold)
        state.syncHRZoneToHoldZone()
        #expect(state.hrZone == .z1Recovery)

        state.zone = .z5VO2Max
        state.syncHRZoneToHoldZone()
        #expect(state.hrZone == .z5VO2Max)
    }

    @Test func syncIsANoOpWhenAlreadyAligned() {
        var state = RideSettingsState(zone: .z2Endurance, hrZone: .z2Endurance)
        state.syncHRZoneToHoldZone()
        #expect(state.hrZone == .z2Endurance)
    }

    /// Z6/Z7 have no `HRZone` counterpart, so the sync must leave `hrZone`
    /// untouched rather than crash or reset it. The picker only offers Z1/Z2
    /// today, but this pins the invariant so a future picker can't desync it.
    @Test func syncLeavesHRZoneUnchangedWhenHoldZoneHasNoHRCounterpart() {
        var state = RideSettingsState(zone: .z6Anaerobic, hrZone: .z3Tempo)
        state.syncHRZoneToHoldZone()
        #expect(state.hrZone == .z3Tempo)

        state.zone = .z7Neuromuscular
        state.syncHRZoneToHoldZone()
        #expect(state.hrZone == .z3Tempo)
    }

    // MARK: zoning (WHOOP-vs-LTHR resolution through the settings type)

    @Test func zoningIsLTHRWithoutWhoopInputs() {
        let state = RideSettingsState(lthr: 158, whoopMaxHR: nil, whoopRestingHR: nil)
        #expect(state.zoning == .lthr(158))
        #expect(!state.zoning.isWhoop)
    }

    @Test func zoningIsWhoopWhenBothInputsPresent() {
        let state = RideSettingsState(
            lthr: 158, whoopMaxHR: 190, whoopRestingHR: 50)
        #expect(state.zoning == .whoopHRR(maxHR: 190, restingHR: 50, lthr: 158))
        #expect(state.zoning.isWhoop)
    }

    @Test func zoningFallsBackToLTHRWithOnlyOneWhoopInput() {
        let onlyMax = RideSettingsState(lthr: 160, whoopMaxHR: 190, whoopRestingHR: nil)
        #expect(onlyMax.zoning == .lthr(160))
        let onlyResting = RideSettingsState(lthr: 160, whoopMaxHR: nil, whoopRestingHR: 50)
        #expect(onlyResting.zoning == .lthr(160))
    }

    @Test func targetHRBandFollowsTheActiveModel() {
        // LTHR model: the band comes from the Friel engine.
        let lthrState = RideSettingsState(lthr: 160, hrZone: .z2Endurance)
        #expect(lthrState.targetHRBand == HRZoneEngine(lthr: 160).bpmRange(for: .z2Endurance))

        // WHOOP model: same zone selection, HRR bands instead.
        let whoopState = RideSettingsState(
            lthr: 160, hrZone: .z2Endurance, whoopMaxHR: 190, whoopRestingHR: 50)
        let expected = HRRZoneEngine(maxHR: 190, restingHR: 50).bpmRange(for: .z2)
        #expect(whoopState.targetHRBand == expected)
    }

    // MARK: storeWhoopInputs / clearWhoopZones

    @Test func storeWhoopInputsSwitchesOntoWhoopZones() {
        var state = RideSettingsState(lthr: 160)
        #expect(!state.zoning.isWhoop)
        state.storeWhoopInputs(maxHR: 188, restingHR: 48)
        #expect(state.whoopMaxHR == 188)
        #expect(state.whoopRestingHR == 48)
        #expect(state.zoning.isWhoop)
    }

    @Test func clearWhoopZonesRevertsToLTHR() {
        var state = RideSettingsState(
            lthr: 160, whoopMaxHR: 188, whoopRestingHR: 48)
        #expect(state.zoning.isWhoop)
        state.clearWhoopZones()
        #expect(state.whoopMaxHR == nil)
        #expect(state.whoopRestingHR == nil)
        #expect(state.zoning == .lthr(160))
    }

    // MARK: hrrEngine (five-band listing on the setup screen)

    @Test func hrrEngineIsNilUntilBothInputsAreSaneAndPresent() {
        #expect(RideSettingsState(whoopMaxHR: nil, whoopRestingHR: nil).hrrEngine == nil)
        #expect(RideSettingsState(whoopMaxHR: 190, whoopRestingHR: nil).hrrEngine == nil)
        // Max at or below resting would make heart-rate reserve non-positive.
        #expect(RideSettingsState(whoopMaxHR: 50, whoopRestingHR: 50).hrrEngine == nil)
        #expect(RideSettingsState(whoopMaxHR: 190, whoopRestingHR: 50).hrrEngine != nil)
    }

    // MARK: target (power)

    @Test func targetUsesFTPAndZone() {
        let state = RideSettingsState(ftp: 200, zone: .z2Endurance, bandPosition: 0.5)
        #expect(state.target == ZoneEngine(ftp: 200).steadyTarget(for: .z2Endurance, position: 0.5))
    }
}
