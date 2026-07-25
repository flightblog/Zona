import Foundation

/// One step of an interval block: hold `zone` for `durationSeconds`. Watts are
/// resolved from `zone` via `ZoneEngine.steadyTarget(for:)` at scheduling time,
/// the same way the steady ride target is — never stored as raw watts.
public struct IntervalStep: Sendable, Equatable, Codable, Identifiable {
    /// Stable across edits so a SwiftUI list can move and delete rows without
    /// the identity churn positional `id`s cause when steps are reordered.
    public var id: UUID
    public var durationSeconds: Int
    public var zone: PowerZone

    public init(id: UUID = UUID(), durationSeconds: Int, zone: PowerZone) {
        self.id = id
        self.durationSeconds = durationSeconds
        self.zone = zone
    }

    /// `id` is presentation identity, not content — a step decoded from an older
    /// blob (which stored no id) mints a fresh one, and two steps that hold the
    /// same zone for the same time are equal regardless of id. Without this,
    /// `IntervalRun`'s `Equatable` conformance would report a re-decoded session
    /// as different from the one in memory.
    public static func == (lhs: IntervalStep, rhs: IntervalStep) -> Bool {
        lhs.durationSeconds == rhs.durationSeconds && lhs.zone == rhs.zone
    }

    private enum CodingKeys: String, CodingKey { case id, durationSeconds, zone }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Pre-step-list blobs carry no `id`.
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        self.zone = try c.decode(PowerZone.self, forKey: .zone)
    }
}

/// A rider-authored interval session: a free-form ordered list of steps, so a
/// warmup, a ramp, or a pyramid is expressible and not just a uniform
/// `repeats × (work, rest)` block.
///
/// **Decoding is back-compatible and must stay that way.** Sessions are
/// persisted in two places: the library in `UserDefaults` (regenerable) and —
/// the load-bearing one — inside `IntervalRun` on every finished `Ride`, which
/// snapshots the session *as ridden* so a later library edit can't restate
/// history. Those older blobs encode `repeats`/`work`/`rest` instead of `steps`,
/// and `Ride.intervalRuns` swallows a decode failure as `[]` — so dropping the
/// legacy path wouldn't error, it would silently empty the interval review on
/// every ride recorded before this shipped. `init(from:)` below reads both.
public struct IntervalSession: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// The steps in ride order. A uniform `4×30/30` is simply eight steps —
    /// repeat structure is implicit in the list rather than a stored count.
    public var steps: [IntervalStep]

    public init(id: UUID = UUID(), name: String, steps: [IntervalStep]) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    /// Builds the uniform shape the pre-step-list model held, by flattening
    /// `repeats × (work, rest)` into a step list. Kept as a convenience because
    /// it's still the most common session a rider authors, and it's what the
    /// legacy decoding path and most tests construct.
    public init(id: UUID = UUID(), name: String, repeats: Int, work: IntervalStep, rest: IntervalStep) {
        self.init(id: id,
                  name: name,
                  steps: (0..<max(0, repeats)).flatMap { _ in
                      // Fresh ids per copy: the same authored step repeated eight
                      // times is eight distinct rows to a SwiftUI list.
                      [IntervalStep(durationSeconds: work.durationSeconds, zone: work.zone),
                       IntervalStep(durationSeconds: rest.durationSeconds, zone: rest.zone)]
                  })
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, steps
        // Legacy keys, read but never written.
        case repeats, work, rest
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Intervals"

        if let steps = try c.decodeIfPresent([IntervalStep].self, forKey: .steps) {
            self.steps = steps
            return
        }
        // Legacy blob: rebuild the flattened list the old `steps` computed
        // property produced, so a ride recorded under the uniform model reviews
        // exactly as it did before. This path stays deliberately lenient —
        // `repeats <= 0` was representable in the old model and meant "no steps",
        // so it decodes rather than throwing.
        if let work = try c.decodeIfPresent(IntervalStep.self, forKey: .work),
           let rest = try c.decodeIfPresent(IntervalStep.self, forKey: .rest) {
            let repeats = try c.decodeIfPresent(Int.self, forKey: .repeats) ?? 0
            self.steps = (0..<max(0, repeats)).flatMap { _ in
                [IntervalStep(durationSeconds: work.durationSeconds, zone: work.zone),
                 IntervalStep(durationSeconds: rest.durationSeconds, zone: rest.zone)]
            }
            return
        }

        // Neither shape present: THROW rather than yielding an empty session.
        // `Ride.intervalRuns` decodes with `try?`, so throwing hides the card
        // entirely — the honest outcome for an unreadable blob. Returning
        // `steps: []` instead would render a card titled "Intervals" reading
        // "No steps · Stopped early · 0:00 of 0:00", i.e. fabricated history
        // presented as real.
        throw DecodingError.dataCorrupted(.init(
            codingPath: c.codingPath,
            debugDescription: "IntervalSession has neither `steps` nor legacy `work`/`rest` keys"))
    }

    /// Encodes the current shape only — legacy keys are read, never written, so
    /// a re-saved session migrates forward.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(steps, forKey: .steps)
    }
}

public extension IntervalSession {
    /// Total block length, ignoring FTP/zone — just the authored durations.
    var totalDurationSeconds: Int {
        steps.reduce(0) { $0 + max(0, $1.durationSeconds) }
    }

    /// One-line summary for list rows, e.g. "4 × (30s Z5 / 30s Z1)" or, for the
    /// canonical free-form shape, "300s Z2 / 4 × (30s Z5 / 30s Z1) / 600s Z2".
    ///
    /// Collapsing runs anywhere in the list — not just across the whole session
    /// — is what keeps a warmup + set + cooldown readable. Scanning only for a
    /// whole-session pair would make the very shape the step list exists to
    /// support render as an unreadable run-on of every step.
    var summary: String {
        guard !steps.isEmpty else { return "No steps" }
        return steps.collapsedRuns()
            .map { $0.description(describe) }
            .joined(separator: " / ")
    }

    private func describe(_ step: IntervalStep) -> String {
        "\(step.durationSeconds)s \(step.zone.shortName)"
    }

    /// True when the whole session is one alternating work/rest pair repeated at
    /// least twice — the shape the pre-step-list model could express, and still
    /// the common one.
    var isUniformSet: Bool {
        guard steps.count >= 4, steps.count.isMultiple(of: 2) else { return false }
        let work = steps[0], rest = steps[1]
        guard work != rest else { return false }
        return !steps.enumerated().contains { $0.offset.isMultiple(of: 2) ? $0.element != work
                                                                          : $0.element != rest }
    }

    /// Where `index` sits in this session's repeat structure, or nil when the
    /// session isn't a uniform set (so there are no reps to count). Lets the
    /// ride HUD say "Rep 3 of 4 · WORK" for the common shape while still
    /// falling back to step counting for a free-form one.
    func repeatPosition(ofStep index: Int) -> IntervalTargetState.RepeatPosition? {
        guard isUniformSet, steps.indices.contains(index) else { return nil }
        return .init(index: index / 2,
                     total: steps.count / 2,
                     isWork: index.isMultiple(of: 2))
    }
}

/// A stretch of the step list collapsed for display: either one step repeated,
/// or a two-step cycle repeated (the classic work/rest set).
private enum StepRun {
    case single(IntervalStep, count: Int)
    case pair(IntervalStep, IntervalStep, count: Int)

    func description(_ describe: (IntervalStep) -> String) -> String {
        switch self {
        case let .single(step, count):
            return count > 1 ? "\(count) × \(describe(step))" : describe(step)
        case let .pair(a, b, count):
            return "\(count) × (\(describe(a)) / \(describe(b)))"
        }
    }
}

private extension Array where Element == IntervalStep {
    /// Walks the list collapsing repeats, preferring the longest alternating
    /// two-step cycle at each position and falling back to runs of one repeated
    /// step. Greedy and left-to-right, which is enough for the shapes riders
    /// actually author (warmup, set, cooldown) without the cost of searching for
    /// an optimal segmentation.
    func collapsedRuns() -> [StepRun] {
        var runs: [StepRun] = []
        var i = 0
        while i < count {
            // Prefer a work/rest cycle: it must repeat at least twice to be
            // worth naming, otherwise "1 × (a / b)" reads worse than "a / b".
            if i + 3 < count, self[i] != self[i + 1],
               self[i] == self[i + 2], self[i + 1] == self[i + 3] {
                var reps = 2
                var j = i + 4
                while j + 1 < count, self[j] == self[i], self[j + 1] == self[i + 1] {
                    reps += 1
                    j += 2
                }
                runs.append(.pair(self[i], self[i + 1], count: reps))
                i = j
                continue
            }
            // Otherwise, a run of the same step repeated.
            var reps = 1
            while i + reps < count, self[i + reps] == self[i] { reps += 1 }
            runs.append(.single(self[i], count: reps))
            i += reps
        }
        return runs
    }
}

private extension Array where Element == IntervalStep {
    /// Consecutive runs of equal steps, as (step, count) pairs.
    func chunkedByEquality() -> [(step: IntervalStep, count: Int)] {
        reduce(into: [(step: IntervalStep, count: Int)]()) { acc, step in
            if let last = acc.last, last.step == step {
                acc[acc.count - 1].count += 1
            } else {
                acc.append((step: step, count: 1))
            }
        }
    }
}
