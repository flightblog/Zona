import Foundation

/// One plotted point of a ride time-series: elapsed seconds plus the two values
/// the ride charts draw. Watts and BPM are optional because a given second may
/// carry only one of them (or, after bucket-averaging, a bucket may hold no
/// readings of one kind). Decoupled from `RideSample` / the app's SwiftData
/// model so the pure reducer below has one input type and the charts map into it.
public struct ChartPoint: Equatable, Sendable {
    public let seconds: Int
    public let watts: Double?
    public let bpm: Double?

    public init(seconds: Int, watts: Double? = nil, bpm: Double? = nil) {
        self.seconds = seconds
        self.watts = watts
        self.bpm = bpm
    }
}

extension Array where Element == ChartPoint {
    /// Reduce a 1 Hz series to at most `maxPoints` evenly-spaced points so Swift
    /// Charts stays responsive: a long ride is thousands of per-second samples,
    /// and plotting a `LineMark` for every one makes the ride/summary screens
    /// lag badly. A chart only a few hundred pixels wide can't resolve more
    /// points than that anyway, so this is lossless to the eye.
    ///
    /// The series is split into `maxPoints` contiguous, equal-count buckets and
    /// each bucket collapses to one point: watts and bpm are the *mean* of the
    /// present values in that bucket (so the line's shape is preserved rather
    /// than aliased by picking every Nth sample), and the point's `seconds` is
    /// the bucket's midpoint so the x-axis stays true to elapsed time. A bucket
    /// with no watts (or no bpm) yields nil for that field, leaving a gap exactly
    /// where the source had one.
    ///
    /// Returns the input unchanged when it already fits within `maxPoints`, so
    /// short rides keep full per-second fidelity.
    public func downsampled(to maxPoints: Int) -> [ChartPoint] {
        guard maxPoints > 0 else { return [] }
        guard count > maxPoints else { return self }

        var result: [ChartPoint] = []
        result.reserveCapacity(maxPoints)

        for bucket in 0..<maxPoints {
            // Evenly partition indices across buckets; integer math spreads any
            // remainder so bucket sizes differ by at most one.
            let start = bucket * count / maxPoints
            let end = (bucket + 1) * count / maxPoints
            guard start < end else { continue }
            let slice = self[start..<end]

            let watts = mean(slice.compactMap(\.watts))
            let bpm = mean(slice.compactMap(\.bpm))
            // Midpoint second of the bucket keeps the x position honest.
            let midSeconds = (slice.first!.seconds + slice.last!.seconds) / 2
            result.append(ChartPoint(seconds: midSeconds, watts: watts, bpm: bpm))
        }
        return result
    }
}

/// Mean of a value list, or nil when empty (so an all-missing bucket stays a gap
/// instead of collapsing to a fabricated 0).
private func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}
