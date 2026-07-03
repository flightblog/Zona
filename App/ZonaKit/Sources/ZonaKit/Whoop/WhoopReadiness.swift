import Foundation

/// A WHOOP recovery band, using WHOOP's own green/yellow/red thresholds. Green
/// (≥67%) means well recovered, yellow (34–66%) moderate, red (<34%) low. Drives
/// the advisory zone suggestion on the setup screen.
public enum WhoopRecoveryBand: Sendable, Equatable {
    case green    // ≥ 67%: recovered
    case yellow   // 34–66%: moderate
    case red      // < 34%: low

    public init(recoveryScore: Int) {
        switch recoveryScore {
        case 67...:  self = .green
        case 34..<67: self = .yellow
        default:     self = .red
        }
    }
}

/// A purely advisory readiness suggestion derived from today's WHOOP recovery.
/// It never changes settings — it only *suggests* how hard to ride, matching the
/// app's Z2-first ethos. `suggestedCeiling` is the hardest zone worth targeting
/// today; `message` is a one-line human summary.
public struct WhoopReadiness: Sendable, Equatable {
    public let band: WhoopRecoveryBand
    public let recoveryScore: Int
    /// The hardest HR zone worth aiming for today (advisory, not enforced).
    public let suggestedCeiling: HRRZone
    public let message: String

    /// Build advice from a recovery score (0–100). Returns nil when WHOOP has no
    /// score yet — there's nothing to advise on.
    public init?(recoveryScore: Int?) {
        guard let recoveryScore else { return nil }
        let band = WhoopRecoveryBand(recoveryScore: recoveryScore)
        self.band = band
        self.recoveryScore = recoveryScore
        switch band {
        case .green:
            suggestedCeiling = .z3
            message = "Well recovered — you've got room for tempo if you want it."
        case .yellow:
            suggestedCeiling = .z2
            message = "Moderate recovery — keep it aerobic, Z2 is the play."
        case .red:
            suggestedCeiling = .z1
            message = "Low recovery — take it easy today, Z1 recovery spin."
        }
    }

    /// Convenience: build straight from a recovery snapshot.
    public init?(from recovery: WhoopRecovery) {
        self.init(recoveryScore: recovery.recoveryScore)
    }
}
