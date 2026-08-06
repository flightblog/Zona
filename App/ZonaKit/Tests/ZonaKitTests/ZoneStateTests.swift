import Foundation
import Testing
@testable import ZonaKit

@Suite("Zone state")
struct ZoneStateTests {
    // LTHR 160 → Friel bands. Z2 Endurance is the usual ride target.
    private let zoning = RideHRZoning.lthr(160)

    // MARK: - Band membership (watts, cadence)

    @Test func bandVariantClassifiesRelativeToTheBand() {
        #expect(ZoneState(value: 100, band: 150...170) == .below)
        #expect(ZoneState(value: 160, band: 150...170) == .inZone)
        #expect(ZoneState(value: 200, band: 150...170) == .above)
    }

    /// The band is inclusive at both ends, so neither edge reads as outside it.
    /// A rider holding exactly the bottom of the window is in it, not below.
    @Test func bandEdgesAreInclusive() {
        #expect(ZoneState(value: 150, band: 150...170) == .inZone)
        #expect(ZoneState(value: 170, band: 150...170) == .inZone)
        #expect(ZoneState(value: 149, band: 150...170) == .below)
        #expect(ZoneState(value: 171, band: 150...170) == .above)
    }

    /// No reading is its own state, never a silent 0 — a dropped strap or an
    /// expired crank meter must not render as "below target", which would tell
    /// the rider to push when there's nothing to push against.
    @Test func missingValueIsNoDataNotBelow() {
        #expect(ZoneState(value: nil, band: 150...170) == .noData)
        #expect(ZoneState(bpm: nil, target: .z2Endurance, zoning: zoning) == .noData)
    }

    // MARK: - HR variant

    @Test func hrVariantClassifiesByZoneNotBand() {
        // Z1 effort against a Z2 target → below; Z4 against Z2 → above.
        #expect(ZoneState(bpm: 100, target: .z2Endurance, zoning: zoning) == .below)
        #expect(ZoneState(bpm: 155, target: .z2Endurance, zoning: zoning) == .above)
    }

    /// The whole reason this variant exists: it must agree with the classifier
    /// the ride is *scored* on, at every BPM, for every target — including the
    /// rounded band edges where a `bpmRange.contains` check disagrees by a beat.
    ///
    /// This is the property a parallel `activeZone == target` comparison would
    /// break, and it's checked exhaustively rather than at sampled points because
    /// the failure is always a single boundary beat.
    @Test func hrVariantAgreesWithTheClassifierAtEveryBPM() {
        for target in HRZone.allCases {
            for bpm in 1...220 {
                let state = ZoneState(bpm: bpm, target: target, zoning: zoning)
                let zone = zoning.zone(forHR: bpm)
                let expected: ZoneState = zone.rawValue < target.rawValue ? .below
                    : zone.rawValue > target.rawValue ? .above : .inZone
                #expect(state == expected, "bpm \(bpm), target \(target)")
            }
        }
    }

    /// Classifying by scanning `bpmRange` instead of `zone(forHR:)` is the bug
    /// this type prevents (a past one lit Z5 at the LTHR boundary). Bands are
    /// inclusive at both ends and Friel Z1's floor is 0, so they overlap at every
    /// shared edge — pinning that a band scan and the real classifier genuinely
    /// disagree somewhere, so nobody "simplifies" the init into the scan.
    @Test func bandScanningWouldDisagreeWithTheClassifier() {
        var disagreements = 0
        for bpm in 1...220 {
            let classified = zoning.zone(forHR: bpm)
            // The naive approach: first band that contains the reading.
            let scanned = HRZone.allCases.first { zoning.bpmRange(for: $0).contains(bpm) }
            if scanned != classified { disagreements += 1 }
        }
        #expect(disagreements > 0)
    }

    /// The HR variant is driven by the *latched* per-ride zoning, so the same BPM
    /// against the same target can be a different state under a different model.
    /// That's what stops a WHOOP reconnect retroactively rewriting a ride.
    @Test func stateFollowsTheZoningModel() {
        let whoop = RideHRZoning.whoopHRR(maxHR: 190, restingHR: 50, lthr: 160)
        let bpms = (1...220).filter {
            ZoneState(bpm: $0, target: .z2Endurance, zoning: zoning)
                != ZoneState(bpm: $0, target: .z2Endurance, zoning: whoop)
        }
        #expect(!bpms.isEmpty)
    }

    // MARK: - Cue

    /// Every state has a distinct spoken/visible cue, and `noData` renders the
    /// "—" placeholder rather than an empty string or a misleading instruction.
    @Test func everyStateHasADistinctCue() {
        let cues = ZoneState.allCases.map(\.cue)
        #expect(Set(cues).count == ZoneState.allCases.count)
        #expect(ZoneState.noData.cue == "—")
        #expect(ZoneState.below.cue.contains("PUSH"))
        #expect(ZoneState.inZone.cue.contains("HOLD"))
        #expect(ZoneState.above.cue.contains("EASE"))
    }
}
