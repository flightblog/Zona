import Foundation

/// One step of an interval block: hold `zone` for `durationSeconds`. Watts are
/// resolved from `zone` via `ZoneEngine.steadyTarget(for:)` at scheduling time,
/// the same way the steady ride target is — never stored as raw watts.
public struct IntervalStep: Sendable, Equatable, Codable {
    public var durationSeconds: Int
    public var zone: PowerZone

    public init(durationSeconds: Int, zone: PowerZone) {
        self.durationSeconds = durationSeconds
        self.zone = zone
    }
}

/// A rider-authored interval session: `repeats` × (one work step, one rest
/// step). v1 deliberately supports only this uniform shape — not a free-form
/// step list — to keep the editor to a reps stepper and two rows.
public struct IntervalSession: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var repeats: Int
    public var work: IntervalStep
    public var rest: IntervalStep

    public init(id: UUID = UUID(), name: String, repeats: Int, work: IntervalStep, rest: IntervalStep) {
        self.id = id
        self.name = name
        self.repeats = repeats
        self.work = work
        self.rest = rest
    }
}

public extension IntervalSession {
    /// The flattened work/rest sequence `IntervalScheduler` steps through:
    /// work, rest, work, rest, … `repeats` times. Empty when `repeats <= 0`.
    var steps: [IntervalStep] {
        guard repeats > 0 else { return [] }
        return (0..<repeats).flatMap { _ in [work, rest] }
    }

    /// Total block length, ignoring FTP/zone — just the authored durations.
    var totalDurationSeconds: Int {
        max(0, repeats) * (work.durationSeconds + rest.durationSeconds)
    }

    /// One-line summary for list rows, e.g. "4 x (30s Z5 / 30s Z1)".
    var summary: String {
        "\(repeats) x (\(work.durationSeconds)s \(work.zone.shortName) / \(rest.durationSeconds)s \(rest.zone.shortName))"
    }
}
