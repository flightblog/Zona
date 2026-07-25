import Foundation

/// Watts-per-kilogram, the one division shared by the live ride screen and the
/// saved ride summary — kept in one pure, tested place rather than duplicated in
/// each view.
public enum PowerPerWeight {
    /// `watts / weightKg`, or nil when either input is missing or the weight
    /// isn't positive — a zero or negative weight makes the ratio meaningless,
    /// not zero.
    public static func wattsPerKg(watts: Int?, weightKg: Double?) -> Double? {
        guard let watts, let weightKg, weightKg > 0 else { return nil }
        return Double(watts) / weightKg
    }
}
