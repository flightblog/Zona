import Foundation

/// Which HR-zone model a ride is scored against.
///
/// Zona has two: the manual Friel/LTHR bands (`HRZoneEngine`) and WHOOP's
/// HRR/Karvonen bands reconstructed from max+resting HR (`HRRZoneEngine`). Which
/// one applies is a property of *the ride* — the rider aimed at whichever model
/// was active when they rode — so a ride carries its zoning and every consumer
/// (target band, time-in-zone, per-zone breakdown, charts) resolves through it.
///
/// Scoring a WHOOP ride against LTHR bands, or rescoring an old LTHR ride against
/// WHOOP bands after connecting WHOOP, would both silently restate history; this
/// type is what stops that. `HRZone`'s raw values (1…5) map 1:1 onto `HRRZone`,
/// so the target zone selection carries across both models unchanged.
public enum RideHRZoning: Sendable, Equatable {
    /// Friel bands as a percentage of lactate threshold HR.
    case lthr(Int)
    /// WHOOP's HRR bands, from max and resting HR. Carries the rider's configured
    /// LTHR too — it plays no part in the scoring here, but it stays recorded
    /// alongside the ride as context (and so the value survives a round-trip
    /// through storage rather than being zeroed out on a WHOOP ride).
    case whoopHRR(maxHR: Int, restingHR: Int, lthr: Int)

    /// The WHOOP zoning when both inputs are present and sane, else the LTHR
    /// fallback. Centralises the "is WHOOP usable?" test that settings and the
    /// persisted ride both need — a max HR at or below resting would make the
    /// heart-rate reserve zero or negative, so it falls back rather than divide
    /// into nonsense.
    public static func resolve(maxHR: Int?, restingHR: Int?, lthr: Int) -> RideHRZoning {
        guard let maxHR, let restingHR, maxHR > restingHR else { return .lthr(lthr) }
        return .whoopHRR(maxHR: maxHR, restingHR: restingHR, lthr: lthr)
    }

    /// True when WHOOP's bands are in play (drives labelling).
    public var isWhoop: Bool {
        if case .whoopHRR = self { return true }
        return false
    }

    // MARK: Persistence
    //
    // A stored ride keeps these three columns; `resolve` turns them back into a
    // zoning. Nil WHOOP fields mean "ridden on LTHR", which is exactly how every
    // ride saved before WHOOP zoning existed reads back.

    /// The LTHR to persist with a ride under this zoning.
    public var storedLTHR: Int {
        switch self {
        case .lthr(let lthr): return lthr
        case .whoopHRR(_, _, let lthr): return lthr
        }
    }

    /// The WHOOP max HR to persist, or nil on an LTHR ride.
    public var storedWhoopMaxHR: Int? {
        if case .whoopHRR(let maxHR, _, _) = self { return maxHR }
        return nil
    }

    /// The WHOOP resting HR to persist, or nil on an LTHR ride.
    public var storedWhoopRestingHR: Int? {
        if case .whoopHRR(_, let restingHR, _) = self { return restingHR }
        return nil
    }

    /// The BPM band for a target zone under this model.
    public func bpmRange(for zone: HRZone) -> ClosedRange<Int> {
        switch self {
        case .lthr(let lthr):
            return HRZoneEngine(lthr: lthr).bpmRange(for: zone)
        case .whoopHRR(let maxHR, let restingHR, _):
            let hrrZone = HRRZone(rawValue: zone.rawValue) ?? .z2
            return HRRZoneEngine(maxHR: maxHR, restingHR: restingHR).bpmRange(for: hrrZone)
        }
    }

    /// Which zone a live/recorded HR reading falls into under this model.
    public func zone(forHR bpm: Int) -> HRZone {
        switch self {
        case .lthr(let lthr):
            return HRZoneEngine(lthr: lthr).zone(forHR: bpm)
        case .whoopHRR(let maxHR, let restingHR, _):
            let hrr = HRRZoneEngine(maxHR: maxHR, restingHR: restingHR).zone(forHR: bpm)
            return HRZone(rawValue: hrr.rawValue) ?? .z1Recovery
        }
    }

    /// Buckets per-second HR readings into each zone, keyed by `HRZone.rawValue`
    /// (1…5). Each reading is one second and lands in exactly one zone, so
    /// boundary BPMs are never double-counted. Zones with no time are omitted.
    public func secondsPerZone(bpms: [Int]) -> [Int: Int] {
        var buckets: [Int: Int] = [:]
        for bpm in bpms {
            buckets[zone(forHR: bpm).rawValue, default: 0] += 1
        }
        return buckets
    }

    /// Seconds of `bpms` falling inside the target zone's band.
    public func secondsInZone(_ zone: HRZone, bpms: [Int]) -> Int {
        let band = bpmRange(for: zone)
        return bpms.filter { band.contains($0) }.count
    }
}
