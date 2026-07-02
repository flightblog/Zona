import Foundation
import Testing
@testable import ZonaKit

@Suite("HRV (RMSSD)")
struct HRVTests {
    /// Build `count` intervals (seconds) alternating between two values so the
    /// successive difference is constant and RMSSD is hand-computable.
    private func alternating(_ a: Double, _ b: Double, count: Int) -> [Double] {
        (0..<count).map { $0.isMultiple(of: 2) ? a : b }
    }

    @Test func knownAnswerAlternatingIntervals() {
        // 30 intervals alternating 0.800 s / 0.840 s. Every successive difference
        // is 40 ms, so RMSSD = sqrt(mean(40²)) = 40 ms exactly. 40/820 ≈ 0.049
        // ratio jump, well under the 0.2 artifact threshold, so none are skipped.
        let rr = alternating(0.800, 0.840, count: 30)
        #expect(HRV.rmssd(intervalsSec: rr) == 40)
    }

    @Test func knownAnswerMixedDifferences() {
        // Repeat the block [800, 820, 790, 810] ms enough times to clear the
        // 20-interval floor. Successive diffs within/across blocks: +20, −30, +20,
        // −10 (wrap 810→800), repeating. Squares: 400, 900, 400, 100. Over a long
        // run the mean → (400+900+400+100)/4 = 450 → sqrt = 21.213… → rounds 21.
        let block = [0.800, 0.820, 0.790, 0.810]
        let rr = Array(repeating: block, count: 10).flatMap { $0 }  // 40 intervals
        #expect(HRV.rmssd(intervalsSec: rr) == 21)
    }

    @Test func returnsNilBelowMinimumIntervals() {
        // 10 intervals < default minIntervals (20) → not enough to report.
        let rr = alternating(0.800, 0.840, count: 10)
        #expect(HRV.rmssd(intervalsSec: rr) == nil)
    }

    @Test func returnsNilOnEmpty() {
        #expect(HRV.rmssd(intervalsSec: []) == nil)
    }

    @Test func rejectsImplausibleIntervals() {
        // A clean 30-interval stream gives 40 ms. Splice in a 0.05 s (=50 ms,
        // ~1200 bpm) and a 5 s (=30 s?? — 12 bpm) reading: both are outside the
        // plausible band and must be dropped, leaving the answer unchanged.
        var rr = alternating(0.800, 0.840, count: 30)
        rr.insert(0.05, at: 5)
        rr.insert(5.0, at: 20)
        #expect(HRV.rmssd(intervalsSec: rr) == 40)
    }

    @Test func skipsEctopicRatioJumpPair() {
        // A clean stream plus one interval that is a sudden ~50% jump from its
        // neighbour (in-band, so not filtered by magnitude, but an artifact by
        // ratio). The pair on each side of it exceeds maxRatioJump and is skipped,
        // so the RMSSD stays the clean-stream value rather than being inflated.
        var rr = alternating(0.800, 0.840, count: 40)
        rr[20] = 1.250   // ~50% jump vs the ~0.82 s neighbours: an ectopic beat
        #expect(HRV.rmssd(intervalsSec: rr) == 40)
    }

    @Test func secondsInMillisecondsOut() {
        // Guard the unit conversion: a constant-difference stream in seconds must
        // produce a millisecond result. 0.500/0.520 alternating → 20 ms diff → 20.
        let rr = alternating(0.500, 0.520, count: 30)
        #expect(HRV.rmssd(intervalsSec: rr) == 20)
    }

    @Test func returnsNilWhenAllPairsAreArtifacts() {
        // Enough in-band intervals to pass the count floor, but every successive
        // pair is a wild jump (>maxRatioJump), so no pair contributes → nil.
        let rr = (0..<30).map { $0.isMultiple(of: 2) ? 0.400 : 1.600 }
        #expect(HRV.rmssd(intervalsSec: rr) == nil)
    }
}
