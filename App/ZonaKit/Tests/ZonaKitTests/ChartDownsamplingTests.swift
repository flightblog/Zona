import Foundation
import Testing
@testable import ZonaKit

@Suite("Chart downsampling")
struct ChartDownsamplingTests {
    /// A series already within budget is returned untouched — short rides keep
    /// full per-second fidelity.
    @Test func shortSeriesUnchanged() {
        let points = (0..<50).map { ChartPoint(seconds: $0, watts: Double($0), bpm: 100) }
        #expect(points.downsampled(to: 200) == points)
    }

    /// Exactly at the budget is still returned unchanged (only *more* than
    /// maxPoints triggers reduction).
    @Test func atBudgetUnchanged() {
        let points = (0..<200).map { ChartPoint(seconds: $0, watts: 10) }
        #expect(points.downsampled(to: 200).count == 200)
        #expect(points.downsampled(to: 200) == points)
    }

    /// A long series is capped at the requested budget.
    @Test func longSeriesCappedToBudget() {
        let points = (0..<3600).map { ChartPoint(seconds: $0, watts: Double($0), bpm: 120) }
        let reduced = points.downsampled(to: 200)
        #expect(reduced.count == 200)
    }

    /// Each bucket averages the values within it — a flat 200 W series stays
    /// 200 W after reduction (no drift from bucketing).
    @Test func bucketAveragesValues() {
        let points = (0..<1000).map { ChartPoint(seconds: $0, watts: 200, bpm: 130) }
        let reduced = points.downsampled(to: 100)
        #expect(reduced.count == 100)
        #expect(reduced.allSatisfy { $0.watts == 200 })
        #expect(reduced.allSatisfy { $0.bpm == 130 })
    }

    /// The averaged value tracks a ramp: the first bucket's mean is near the low
    /// end, the last bucket's mean near the high end. Confirms shape is preserved,
    /// not aliased.
    @Test func averagePreservesRampShape() {
        let points = (0..<1000).map { ChartPoint(seconds: $0, watts: Double($0)) }
        let reduced = points.downsampled(to: 10)
        #expect(reduced.count == 10)
        // First bucket spans 0..<100 → mean ~49.5; last spans 900..<1000 → ~949.5.
        #expect(reduced.first!.watts! < 100)
        #expect(reduced.last!.watts! > 900)
        // Monotonic non-decreasing means for a monotonic input.
        let watts = reduced.compactMap(\.watts)
        #expect(zip(watts, watts.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// A bucket with no readings of a field yields nil for that field — a real
    /// gap, never a fabricated 0. Here watts exist only in the first half.
    @Test func missingFieldStaysGap() {
        let points = (0..<1000).map { i in
            ChartPoint(seconds: i, watts: i < 500 ? 150 : nil, bpm: 120)
        }
        let reduced = points.downsampled(to: 10)
        // Early buckets have watts; late buckets (all-nil) must be nil, not 0.
        #expect(reduced.first!.watts == 150)
        #expect(reduced.last!.watts == nil)
        // BPM is present throughout, so no bucket drops it.
        #expect(reduced.allSatisfy { $0.bpm == 120 })
    }

    /// The x position of each bucket is its midpoint second, so the time axis
    /// stays true rather than snapping to a bucket edge.
    @Test func secondsUseBucketMidpoint() {
        let points = (0..<1000).map { ChartPoint(seconds: $0, watts: 100) }
        let reduced = points.downsampled(to: 10)
        // First bucket 0..<100 → midpoint of first(0) and last(99) = 49.
        #expect(reduced.first!.seconds == 49)
    }

    /// Degenerate budgets don't crash: 0 (or negative) yields an empty result.
    @Test func zeroBudgetIsEmpty() {
        let points = (0..<10).map { ChartPoint(seconds: $0, watts: 1) }
        #expect(points.downsampled(to: 0).isEmpty)
    }
}
