import Foundation

/// Where a live reading sits relative to its target, and the correction it
/// implies — below (push harder), in zone (hold), above (ease off), or no data.
///
/// **This is the single on-target decision.** The BPM dial's PUSH/HOLD/EASE chip,
/// the Z1–Z5 zone bar's outlined target segment and tinted handle, and that bar's
/// VoiceOver phrase all read this one value rather than each comparing a reading
/// to a target themselves. A parallel `activeZone == target` check anywhere would
/// be free to disagree at a band edge, which is exactly the beat-for-beat
/// agreement PR #76 and #107 established.
///
/// Pure and `Sendable`: the *decision* lives here where it's unit-tested, while
/// how a state is painted stays in the app target (`ZoneState.tint`), the same
/// split `HRZone.color` already uses. Don't drag SwiftUI in here to reunite them.
public enum ZoneState: Sendable, Equatable, CaseIterable {
    case noData, below, inZone, above

    /// Band-membership variant, for readings with no zone model behind them
    /// (watts, cadence): straightforward containment in the target range.
    public init(value: Int?, band: ClosedRange<Int>) {
        guard let value else { self = .noData; return }
        if value < band.lowerBound { self = .below }
        else if value > band.upperBound { self = .above }
        else { self = .inZone }
    }

    /// HR variant: judge in/below/above by which *zone* the reading classifies
    /// into, not by whether it falls inside the rounded target band. The two can
    /// disagree by a beat at every band edge, because `bpmRange` rounds each edge
    /// independently while `zone(forHR:)` compares the raw fraction — and
    /// `zone(forHR:)` is what the ride is actually scored on. Routing the dial's
    /// green state through the classifier keeps it, the zone bar, the live
    /// in-zone timer and the summary's time-in-zone in exact agreement.
    ///
    /// Never classify by scanning `bpmRange` bands: they're inclusive at both
    /// ends and Friel Z1's floor is 0, so a scan misreads every rounded edge (a
    /// past bug lit Z5 at the LTHR boundary). See `RideHRZoning.zone(forHR:)`.
    public init(bpm: Int?, target: HRZone, zoning: RideHRZoning) {
        guard let bpm else { self = .noData; return }
        let zone = zoning.zone(forHR: bpm)
        if zone.rawValue < target.rawValue { self = .below }
        else if zone.rawValue > target.rawValue { self = .above }
        else { self = .inZone }
    }

    /// Short verb + arrow telling the rider how to correct. Glanceable mid-ride
    /// and readable without relying on colour perception alone.
    public var cue: String {
        switch self {
        case .noData: return "—"
        case .below:  return "↑ PUSH"
        case .inZone: return "✓ HOLD"
        case .above:  return "↓ EASE"
        }
    }
}
