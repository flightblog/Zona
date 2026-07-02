import Foundation

/// Heart-rate-variability math over a ride's R-R (beat-to-beat) intervals.
///
/// Pure and `Sendable` — no Bluetooth, no storage, no wall clock — so it unit
/// tests exactly like `ZoneEngine`/`HRZoneEngine`/`HRHoldController`. The HR
/// strap already reports R-R intervals (`HeartRateMeasurement.rrIntervals`, in
/// seconds); the app concatenates a ride's intervals and calls `rmssd` for a
/// single summary number.
///
/// **RMSSD** (root mean square of successive differences) is the standard
/// short-term HRV metric — the one WHOOP/Oura/Garmin report — because it's
/// derivable from a single ride's R-R stream without frequency-domain analysis
/// and degrades gracefully with short samples. Higher RMSSD ≈ more parasympathetic
/// (recovered) tone; a steady Z2 ride is a reasonable place to sample it.
public enum HRV {
    /// RMSSD in **milliseconds** over successive R-R intervals (supplied in
    /// **seconds**, as the HR characteristic reports them).
    ///
    /// Returns `nil` when fewer than `minIntervals` usable intervals survive
    /// filtering — too few beats for the number to mean anything (the app shows
    /// "—" in that case rather than a misleading value).
    ///
    /// Artifact handling (ectopic/dropped beats wreck RMSSD, which squares
    /// differences):
    /// - Drop any interval outside `[minRRms, maxRRms]` (implausible HR).
    /// - When walking successive pairs, skip a pair whose relative change exceeds
    ///   `maxRatioJump` — a jump that large is almost always an artifact, not a
    ///   real beat-to-beat change — but keep counting the run from the later beat.
    ///
    /// - Parameters:
    ///   - intervalsSec: R-R intervals in seconds, in order.
    ///   - minIntervals: minimum plausible intervals required to report (default
    ///     20 — roughly 20–30 s of beats; below this RMSSD is too noisy).
    ///   - minRRms: shortest plausible interval in ms (default 300 ≈ 200 bpm).
    ///   - maxRRms: longest plausible interval in ms (default 2000 ≈ 30 bpm).
    ///   - maxRatioJump: max fractional change between successive kept intervals
    ///     before the pair is treated as an artifact and skipped (default 0.2).
    /// - Returns: RMSSD in whole milliseconds, or `nil` if too few usable beats.
    public static func rmssd(intervalsSec: [Double],
                             minIntervals: Int = 20,
                             minRRms: Double = 300,
                             maxRRms: Double = 2000,
                             maxRatioJump: Double = 0.2) -> Int? {
        // To milliseconds, keeping only physiologically plausible intervals.
        let plausible = intervalsSec
            .map { $0 * 1000.0 }
            .filter { $0 >= minRRms && $0 <= maxRRms }

        guard plausible.count >= minIntervals else { return nil }

        // Sum squared successive differences, skipping pairs that jump too far to
        // be a real beat-to-beat change (ectopic/dropped beat). We still advance
        // the "previous" interval so the run continues from the later beat.
        var sumSquares = 0.0
        var pairs = 0
        var previous = plausible[0]
        for current in plausible.dropFirst() {
            let jump = abs(current - previous) / previous
            if jump <= maxRatioJump {
                let diff = current - previous
                sumSquares += diff * diff
                pairs += 1
            }
            previous = current
        }

        guard pairs > 0 else { return nil }
        return Int((sumSquares / Double(pairs)).squareRoot().rounded())
    }
}
