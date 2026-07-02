import Foundation

/// The outcome of one `HRHoldController` update: either a new ERG watt target to
/// command, or `nil` (hold — either in-band, cooling down, or no HR). `reason` is
/// human-readable for the ride event log, e.g. "HR 152 > Z2 148+4, ease −5 W".
public struct HRHoldDecision: Sendable, Equatable {
    public let newTargetW: Int?
    public let reason: String

    public init(newTargetW: Int?, reason: String) {
        self.newTargetW = newTargetW
        self.reason = reason
    }

    /// No change this tick.
    static func hold(_ reason: String) -> HRHoldDecision {
        HRHoldDecision(newTargetW: nil, reason: reason)
    }
}

/// Closed-loop HR→watts controller: gently walks the ERG watt target to keep
/// heart rate inside a target band. Deliberately slow, damped, and clamped —
/// heart rate lags power by ~20–60 s, so a fast controller oscillates.
///
/// Pure and `Sendable`: no Bluetooth, no UI, no wall clock (time is passed in as
/// seconds), so it's fully unit-testable like `ZoneEngine`/`HRZoneEngine`. The
/// app drives `update(...)` once a second from the ride screen and applies the
/// returned target via `TrainerController.setTargetPower`.
///
/// Control law (see the ride plan for rationale):
/// - **Deadband:** ignore HR within the band or within `deadbandBpm` of it.
/// - **Persistence:** the breakout must last ≥ `cooldownSeconds` before the first
///   adjustment, so a single stray sample never moves watts.
/// - **Cooldown:** after adjusting, wait `cooldownSeconds` before adjusting again,
///   giving the change time to show up in HR.
/// - **Symmetric:** HR too high → step down; HR too low → step up; same gentle
///   step either way.
/// - **Step:** `stepW`, growing to `farStepW` when HR is > `farBpm` past the band.
/// - **Clamp:** the new target is always kept inside `wattClamp`.
/// - **HR dropout:** nil HR → hold the last target (never act on missing data).
public struct HRHoldController: Sendable {
    // Tuning — defaults are the plan's starting constants; tune on hardware.
    public var deadbandBpm: Int
    public var cooldownSeconds: Double
    public var stepW: Int
    public var farStepW: Int
    public var farBpm: Int

    public init(deadbandBpm: Int = 4,
                cooldownSeconds: Double = 30,
                stepW: Int = 5,
                farStepW: Int = 10,
                farBpm: Int = 8) {
        self.deadbandBpm = deadbandBpm
        self.cooldownSeconds = cooldownSeconds
        self.stepW = stepW
        self.farStepW = farStepW
        self.farBpm = farBpm
    }

    // Mutable state across ticks.
    /// Time of the last watt adjustment (nil = none yet this session).
    private var lastAdjustAt: Double?
    /// When the current sustained breakout began, and its sign (+1 over, −1 under).
    /// Cleared whenever HR returns to the deadband.
    private var breakoutSince: Double?
    private var breakoutSign: Int = 0

    /// Re-arm the persistence/cooldown timers as if an adjustment just happened at
    /// `now`. Call this when the rider makes a MANUAL target change, so auto-hold
    /// doesn't immediately fight it. Also clears any pending breakout.
    public mutating func noteManualAdjust(at now: Double) {
        lastAdjustAt = now
        breakoutSince = nil
        breakoutSign = 0
    }

    /// Decide whether to move the ERG target this tick.
    ///
    /// - Parameters:
    ///   - hr: latest heart rate (nil if no live reading → hold).
    ///   - currentTargetW: the ERG target currently commanded.
    ///   - band: the rider's target HR band (bpm), from `HRZoneEngine`.
    ///   - wattClamp: watts are never commanded outside this (the power-zone band).
    ///   - now: monotonic time in seconds (test-injectable).
    public mutating func update(hr: Int?,
                                currentTargetW: Int,
                                band: ClosedRange<Int>,
                                wattClamp: ClosedRange<Int>,
                                now: Double) -> HRHoldDecision {
        // No live HR → never act on missing data.
        guard let hr else {
            breakoutSince = nil
            breakoutSign = 0
            return .hold("no HR — holding \(currentTargetW) W")
        }

        // How far outside the band are we (0 if inside)? Positive = over.
        let over = hr - band.upperBound          // >0 when HR too high
        let under = band.lowerBound - hr         // >0 when HR too low
        let sign: Int
        let excess: Int
        if over > 0 { sign = +1; excess = over }
        else if under > 0 { sign = -1; excess = under }
        else { sign = 0; excess = 0 }

        // Inside the band, or within the deadband margin of it → nothing to do.
        if sign == 0 || excess <= deadbandBpm {
            breakoutSince = nil
            breakoutSign = 0
            return .hold("HR \(hr) in \(band.lowerBound)–\(band.upperBound) (±\(deadbandBpm)) — hold")
        }

        // A real breakout. Track when it started (reset if direction flipped).
        if breakoutSince == nil || breakoutSign != sign {
            breakoutSince = now
            breakoutSign = sign
        }

        // Require the breakout to persist a full cooldown window before the FIRST
        // move, so a brief spike doesn't trigger a change.
        let heldFor = now - (breakoutSince ?? now)
        if heldFor < cooldownSeconds {
            return .hold("HR \(hr) breaking out \(heldFor.rounded())s — waiting")
        }

        // Respect the cooldown between successive adjustments.
        if let last = lastAdjustAt, now - last < cooldownSeconds {
            return .hold("HR \(hr) out of band — cooling down")
        }

        // Commit a step. Direction is opposite the HR excursion: HR high → watts
        // down; HR low → watts up. Bigger step when far outside.
        let magnitude = excess > farBpm ? farStepW : stepW
        let delta = -sign * magnitude
        let clamped = min(max(currentTargetW + delta, wattClamp.lowerBound), wattClamp.upperBound)

        // Already at the clamp in the needed direction → nothing to give.
        guard clamped != currentTargetW else {
            return .hold("HR \(hr) out of band but watts at \(sign > 0 ? "floor" : "ceiling") \(currentTargetW) W")
        }

        lastAdjustAt = now
        // Keep the breakout timer running (still out of band) so a continued drift
        // adjusts again after the next cooldown, without re-waiting persistence.
        let verb = sign > 0 ? "ease" : "push"
        let arrow = delta < 0 ? "−" : "+"
        let reason = "HR \(hr) \(sign > 0 ? ">" : "<") band \(band.lowerBound)–\(band.upperBound), \(verb) \(arrow)\(abs(delta)) W → \(clamped) W"
        return HRHoldDecision(newTargetW: clamped, reason: reason)
    }
}
