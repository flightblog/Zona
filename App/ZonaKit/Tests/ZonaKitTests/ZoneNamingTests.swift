import Testing
@testable import ZonaKit

/// Zona has three parallel zone models — `PowerZone` (Coggan, FTP-based),
/// `HRZone` (Friel, LTHR-based) and `HRRZone` (WHOOP/Karvonen, reserve-based) —
/// and their display names were deliberately unified to WHOOP's naming so the
/// setup screen, the live ride screen and the summary all read alike whichever
/// model a ride was ridden under.
///
/// Nothing else pins that: the names are three independent `switch` statements in
/// three files, so renaming a case in one silently desyncs the UI from the other
/// two. These tests are the cross-model contract.
struct ZoneNamingTests {

    // MARK: Short names (the Z1…Z7 chips on the ride screen and zone bar)

    @Test func powerShortNamesAreZPlusRawValue() {
        #expect(PowerZone.z1Recovery.shortName == "Z1")
        #expect(PowerZone.z2Endurance.shortName == "Z2")
        #expect(PowerZone.z3Tempo.shortName == "Z3")
        #expect(PowerZone.z4Threshold.shortName == "Z4")
        #expect(PowerZone.z5VO2Max.shortName == "Z5")
        #expect(PowerZone.z6Anaerobic.shortName == "Z6")
        #expect(PowerZone.z7Neuromuscular.shortName == "Z7")
    }

    /// `PowerZone.shortName` is a hand-written switch (unlike `HRZone`'s
    /// interpolation), so it can drift from the raw value it's meant to mirror.
    /// `IntervalSession.summary` renders these into "4 x (30s Z5 / 30s Z1)", so a
    /// mismatch would misdescribe a saved session.
    @Test func everyPowerShortNameMatchesItsRawValue() {
        for zone in PowerZone.allCases {
            #expect(zone.shortName == "Z\(zone.rawValue)")
        }
    }

    @Test func everyHRShortNameMatchesItsRawValue() {
        for zone in HRZone.allCases {
            #expect(zone.shortName == "Z\(zone.rawValue)")
        }
    }

    // MARK: Full names (the unified WHOOP-style naming)

    /// The five zones all three models have in common must carry byte-identical
    /// full names. This is the actual unification invariant: Z1–Z5 read the same
    /// whether the screen is showing a power zone, an LTHR zone, or a WHOOP/HRR
    /// zone. All three are hand-written `switch`es over the same literals, so
    /// this is the only thing holding them together.
    @Test func allThreeModelsAgreeOnTheSharedZoneNames() {
        for hrZone in HRZone.allCases {
            let powerZone = PowerZone(rawValue: hrZone.rawValue)
            let hrrZone = HRRZone(rawValue: hrZone.rawValue)
            #expect(powerZone != nil, "HRZone \(hrZone.rawValue) has no PowerZone counterpart")
            #expect(hrrZone != nil, "HRZone \(hrZone.rawValue) has no HRRZone counterpart")
            #expect(hrZone.name == powerZone?.name)
            #expect(hrZone.name == hrrZone?.name)
            #expect(hrZone.shortName == powerZone?.shortName)
            #expect(hrZone.shortName == hrrZone?.shortName)
        }
    }

    /// The names themselves, pinned literally — so a rename shows up as a failing
    /// assertion naming the old and new string, rather than only as two models
    /// silently agreeing on something new.
    @Test func sharedZoneNamesAreTheWhoopNaming() {
        #expect(HRZone.z1Recovery.name == "Z1 Recovery")
        #expect(HRZone.z2Endurance.name == "Z2 Endurance")
        #expect(HRZone.z3Tempo.name == "Z3 Tempo")
        #expect(HRZone.z4Threshold.name == "Z4 Threshold")
        #expect(HRZone.z5VO2Max.name == "Z5 Max")
    }

    /// Power's two extra zones have no HR counterpart (Friel/WHOOP stop at Z5),
    /// so they're named on their own — but still in the same "Zn Label" shape.
    @Test func powerOnlyZonesFollowTheSameNameShape() {
        #expect(PowerZone.z6Anaerobic.name == "Z6 Anaerobic")
        #expect(PowerZone.z7Neuromuscular.name == "Z7 Neuromuscular")
    }

    /// Every full name starts with its own short name, across both models — the
    /// shape the UI relies on when it shows a name where a chip won't fit.
    @Test func everyFullNameIsPrefixedByItsShortName() {
        for zone in PowerZone.allCases {
            #expect(zone.name.hasPrefix(zone.shortName + " "))
        }
        for zone in HRZone.allCases {
            #expect(zone.name.hasPrefix(zone.shortName + " "))
        }
        for zone in HRRZone.allCases {
            #expect(zone.name.hasPrefix(zone.shortName + " "))
        }
    }

    // MARK: HRR ↔ HRZone correspondence

    /// `RideHRZoning` maps between `HRZone` and `HRRZone` by raw value when a ride
    /// is scored under WHOOP's bands, so the two enums must stay index-aligned —
    /// same count, same raw values. If they drift, WHOOP-zoned rides would score
    /// against the wrong band (or force-unwrap nil in the zoning facade).
    @Test func hrrZonesAlignWithHRZonesByRawValue() {
        #expect(HRRZone.allCases.count == HRZone.allCases.count)
        for hrZone in HRZone.allCases {
            #expect(HRRZone(rawValue: hrZone.rawValue) != nil)
        }
        for hrrZone in HRRZone.allCases {
            #expect(HRZone(rawValue: hrrZone.rawValue) != nil)
        }
    }
}
