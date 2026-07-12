import SwiftUI
import ZonaKit

extension HRZone {
    /// Cool→warm across Z1–Z5, so the effort ramp reads at a glance. Shared by
    /// every zone display (the ride screen's live zone bar, the all-time per-zone
    /// breakdown) so the same zone is the same color wherever it appears — a
    /// second copy of this ramp would eventually drift from the first.
    ///
    /// Deliberately app-target, not `ZonaKit`: the zone *math* is pure and tested,
    /// but how a zone is painted is a UI concern and would drag SwiftUI into the
    /// package for nothing.
    var color: Color {
        switch self {
        case .z1Recovery:  return .blue
        case .z2Endurance: return .green
        case .z3Tempo:     return .yellow
        case .z4Threshold: return .orange
        case .z5VO2Max:    return .red
        }
    }
}
