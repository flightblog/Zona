import Foundation
import Testing
@testable import ZonaKit

@Suite("HR-hold controller")
struct HRHoldTests {
    // A Z2 rider: target HR band 130…148, ERG clamp 110…150 W (the power-zone
    // band), starting target 130 W. Defaults: deadband 4, cooldown 30 s, step 5 W.
    let band = 130...148
    let clamp = 110...150

    private func controller() -> HRHoldController { HRHoldController() }

    @Test func holdsWhenInBand() {
        var c = controller()
        let d = c.update(hr: 140, currentTargetW: 130, band: band, wattClamp: clamp, now: 0)
        #expect(d.newTargetW == nil)
    }

    @Test func holdsWithinDeadbandAboveBand() {
        // 148 band top + 4 deadband = ignore up to 152.
        var c = controller()
        #expect(c.update(hr: 151, currentTargetW: 130, band: band, wattClamp: clamp, now: 0).newTargetW == nil)
        #expect(c.update(hr: 151, currentTargetW: 130, band: band, wattClamp: clamp, now: 40).newTargetW == nil)
    }

    @Test func holdsOnNilHR() {
        var c = controller()
        let d = c.update(hr: nil, currentTargetW: 130, band: band, wattClamp: clamp, now: 100)
        #expect(d.newTargetW == nil)
        #expect(d.reason.contains("no HR"))
    }

    @Test func easesDownAfterSustainedOverBand() {
        // HR 154: over by 6 (>deadband 4, ≤far 8) → a single −5 W step, but only
        // after the breakout has persisted a full cooldown window (30 s).
        var c = controller()
        #expect(c.update(hr: 154, currentTargetW: 130, band: band, wattClamp: clamp, now: 0).newTargetW == nil)
        #expect(c.update(hr: 154, currentTargetW: 130, band: band, wattClamp: clamp, now: 20).newTargetW == nil)
        let d = c.update(hr: 154, currentTargetW: 130, band: band, wattClamp: clamp, now: 30)
        #expect(d.newTargetW == 125)   // 130 − 5
        #expect(d.reason.contains("ease"))
    }

    @Test func pushesUpAfterSustainedUnderBand() {
        // HR 124: under by 6 (near) → raise watts +5, symmetric to easing down.
        var c = controller()
        _ = c.update(hr: 124, currentTargetW: 130, band: band, wattClamp: clamp, now: 0)
        let d = c.update(hr: 124, currentTargetW: 130, band: band, wattClamp: clamp, now: 30)
        #expect(d.newTargetW == 135)   // 130 + 5
        #expect(d.reason.contains("push"))
    }

    @Test func usesLargerStepWhenFarOutside() {
        // > farBpm (8) past the band → 10 W step. 148 + 8 = 156, so 160 is "far".
        var c = controller()
        _ = c.update(hr: 160, currentTargetW: 130, band: band, wattClamp: clamp, now: 0)
        let d = c.update(hr: 160, currentTargetW: 130, band: band, wattClamp: clamp, now: 30)
        #expect(d.newTargetW == 120)   // 130 − 10
    }

    @Test func respectsCooldownBetweenAdjustments() {
        // HR 154 (near, 5 W step). First step at t=30; the next tick 10 s later
        // must hold (cooldown), even though HR is still out of band. Only after
        // another 30 s does it step again.
        var c = controller()
        _ = c.update(hr: 154, currentTargetW: 130, band: band, wattClamp: clamp, now: 0)
        let first = c.update(hr: 154, currentTargetW: 130, band: band, wattClamp: clamp, now: 30)
        #expect(first.newTargetW == 125)
        #expect(c.update(hr: 154, currentTargetW: 125, band: band, wattClamp: clamp, now: 40).newTargetW == nil)
        let second = c.update(hr: 154, currentTargetW: 125, band: band, wattClamp: clamp, now: 60)
        #expect(second.newTargetW == 120)   // 125 − 5
    }

    @Test func dampsOscillationDoesNotStepEverySecond() {
        // Drive a full minute of over-band HR at 1 Hz; expect at most 2 changes
        // (t≈30 and t≈60), NOT ~60. This is the anti-oscillation guarantee.
        var c = controller()
        var target = 140            // start mid-clamp so steps don't hit floor
        var changes = 0
        for t in 0...60 {
            let d = c.update(hr: 158, currentTargetW: target, band: band, wattClamp: clamp, now: Double(t))
            if let n = d.newTargetW { target = n; changes += 1 }
        }
        #expect(changes <= 2)
        #expect(target < 140)       // it did move down
    }

    @Test func clampsAtPowerZoneFloor() {
        // At the clamp floor (110 W) with HR still high, it can't go lower → hold.
        var c = controller()
        _ = c.update(hr: 158, currentTargetW: 110, band: band, wattClamp: clamp, now: 0)
        let d = c.update(hr: 158, currentTargetW: 110, band: band, wattClamp: clamp, now: 30)
        #expect(d.newTargetW == nil)
        #expect(d.reason.contains("floor"))
    }

    @Test func clampsAtPowerZoneCeiling() {
        // At the ceiling (150 W) with HR too low, it can't go higher → hold.
        var c = controller()
        _ = c.update(hr: 118, currentTargetW: 150, band: band, wattClamp: clamp, now: 0)
        let d = c.update(hr: 118, currentTargetW: 150, band: band, wattClamp: clamp, now: 30)
        #expect(d.newTargetW == nil)
        #expect(d.reason.contains("ceiling"))
    }

    @Test func briefSpikeDoesNotTriggerAdjustment() {
        // A single over-band sample, then back in band → the persistence window
        // is never satisfied, so no change.
        var c = controller()
        #expect(c.update(hr: 160, currentTargetW: 130, band: band, wattClamp: clamp, now: 0).newTargetW == nil)
        #expect(c.update(hr: 140, currentTargetW: 130, band: band, wattClamp: clamp, now: 1).newTargetW == nil)
        #expect(c.update(hr: 140, currentTargetW: 130, band: band, wattClamp: clamp, now: 35).newTargetW == nil)
    }

    @Test func manualAdjustResetsCooldown() {
        // After a manual nudge at t=10, auto-hold must re-wait a full window from
        // then, so it doesn't immediately fight the rider. HR 154 → near, 5 W.
        var c = controller()
        _ = c.update(hr: 154, currentTargetW: 130, band: band, wattClamp: clamp, now: 0)  // breakout starts
        c.noteManualAdjust(at: 10)   // rider nudged; clears breakout + arms cooldown
        // Breakout is re-observed fresh at the next tick (t=30) and must persist a
        // full window from there — so it holds at t=45 and only acts at t≥60.
        #expect(c.update(hr: 154, currentTargetW: 125, band: band, wattClamp: clamp, now: 30).newTargetW == nil)
        #expect(c.update(hr: 154, currentTargetW: 125, band: band, wattClamp: clamp, now: 45).newTargetW == nil)
        #expect(c.update(hr: 154, currentTargetW: 125, band: band, wattClamp: clamp, now: 60).newTargetW == 120)
    }

    @Test func directionFlipRestartsPersistence() {
        // Over-band for a while, then HR swings under-band: the new (opposite)
        // breakout must serve its own persistence window before acting. HR 124 →
        // under by 6 (near), so +5 W.
        var c = controller()
        _ = c.update(hr: 154, currentTargetW: 130, band: band, wattClamp: clamp, now: 0)
        // Flip to under-band at t=20; must wait until t≈50, not fire at t=30.
        #expect(c.update(hr: 124, currentTargetW: 130, band: band, wattClamp: clamp, now: 20).newTargetW == nil)
        #expect(c.update(hr: 124, currentTargetW: 130, band: band, wattClamp: clamp, now: 40).newTargetW == nil)
        #expect(c.update(hr: 124, currentTargetW: 130, band: band, wattClamp: clamp, now: 50).newTargetW == 135)
    }
}
