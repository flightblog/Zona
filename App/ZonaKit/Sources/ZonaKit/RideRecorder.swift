import Foundation
import Observation

/// One second of a ride. `secondsFromStart` is the whole-second bucket, so the
/// recorder holds at most one sample per second regardless of how fast FTMS
/// notifications arrive.
public struct RideSample: Sendable, Equatable {
    public let secondsFromStart: Int
    public var powerW: Int?
    public var cadenceRpm: Int?
    public var speedKph: Double?
    public var heartRateBpm: Int?
    /// Watts from a connected SRAM/Quarq crank meter this second, when one was
    /// paired — the rider's *leg* power, recorded alongside (never merged into)
    /// the trainer's `powerW`. nil on every sample of a ride ridden without a
    /// meter, and on any second the meter didn't report — including a coast,
    /// where `ingest` actively clears this back to nil rather than letting the
    /// last-seen wattage stick (see the assignment in `ingest`).
    ///
    /// This is a second, parallel channel: `powerW` remains the ride's source of
    /// truth for what ERG held and what the zone math scores. It exists so a ride
    /// can be reviewed against true crank power after the fact — and so the TCX
    /// export can ship crank watts when this channel covered the ride, matching
    /// how the same rider's outdoor rides are recorded (see `TCXPowerSource`).
    /// The two differ by a few watts by design — see `RideMetrics.powerMeterW`.
    public var powerMeterW: Int?
    /// Every R-R interval (seconds) captured during this second — *accumulated*
    /// across the second's HR notifications (a second can hold 1–3 beats), unlike
    /// the last-write-wins scalar fields. nil when the strap reports no R-R. Feeds
    /// per-ride HRV (`HRV.rmssd` over the whole ride's concatenated intervals).
    public var rrIntervalsSec: [Double]?

    public init(secondsFromStart: Int,
                powerW: Int? = nil,
                cadenceRpm: Int? = nil,
                speedKph: Double? = nil,
                heartRateBpm: Int? = nil,
                powerMeterW: Int? = nil,
                rrIntervalsSec: [Double]? = nil) {
        self.secondsFromStart = secondsFromStart
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
        self.powerMeterW = powerMeterW
        self.rrIntervalsSec = rrIntervalsSec
    }
}

/// A finished ride: the inputs it was ridden at plus its 1 Hz samples. Pure
/// value type — the app maps this into SwiftData.
public struct RideRecording: Sendable, Equatable {
    public let ftp: Int
    public let zone: PowerZone
    public let startedAt: Date
    /// Wall-clock ride length in whole seconds, from `start(...)` to `finish()`,
    /// measured on a monotonic clock. This is the ride's *duration* — distinct
    /// from `samples.count`, which is only the number of seconds that captured
    /// data. They diverge when seconds pass without a fresh metrics sample (a
    /// dropped FTMS notification, or a steady stretch where the app didn't
    /// re-ingest), so duration must come from here, not from counting samples.
    /// 0 for recordings built by hand (tests) — callers fall back to sample count.
    public let durationSeconds: Int
    public let samples: [RideSample]
    /// Interval sessions that ran during the ride, in the order they started.
    /// Empty for a plain steady ride. Powers the summary's interval review.
    public let intervalRuns: [IntervalRun]

    public init(ftp: Int, zone: PowerZone, startedAt: Date, samples: [RideSample],
                durationSeconds: Int = 0, intervalRuns: [IntervalRun] = []) {
        self.ftp = ftp
        self.zone = zone
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.samples = samples
        self.intervalRuns = intervalRuns
    }
}

/// Accumulates live `RideMetrics` into 1 Hz samples during a ride.
///
/// FTMS pushes Indoor Bike Data several times a second; `ingest` collapses those
/// into one sample per whole second (last write within the second wins for each
/// field). Time is measured from `start(...)` using a monotonic clock so it is
/// unaffected by wall-clock changes mid-ride.
@MainActor
@Observable
public final class RideRecorder {
    public private(set) var isRecording = false
    /// Live count of seconds captured — handy for a ride timer in the UI.
    public private(set) var elapsedSeconds = 0

    @ObservationIgnored private var ftp = 0
    @ObservationIgnored private var zone: PowerZone = .z2Endurance
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var startInstant = ContinuousClock.now
    // Keyed by whole-second bucket; flattened + sorted in `finish()`.
    @ObservationIgnored private var samplesBySecond: [Int: RideSample] = [:]
    // Interval sessions that ran, in start order — appended via `recordInterval`.
    @ObservationIgnored private var intervalRuns: [IntervalRun] = []

    public init() {}

    /// The seconds captured so far, in time order. Reading it re-renders when new
    /// samples land, so the live ride screen can plot a running time-series of the
    /// values (e.g. watts and BPM). Mirrors the ordering `finish()` produces, so a
    /// live chart and the saved ride agree on the sequence.
    public var samples: [RideSample] {
        samplesBySecond.values.sorted { $0.secondsFromStart < $1.secondsFromStart }
    }

    /// Live accumulated distance in metres, integrating trainer speed the same
    /// stepwise way `RideRecording.distanceMeters` does at ride's end (each
    /// second's speed held until the next; no interpolation across gaps). Reading
    /// it re-renders when new samples land, so the ride screen can show a running
    /// total. Matches the saved-ride figure once recording finishes.
    public var distanceMeters: Double {
        let ordered = samples
        var metres = 0.0
        for i in 0..<ordered.count {
            guard i + 1 < ordered.count else { break }
            guard let kph = ordered[i].speedKph else { continue }
            let dt = ordered[i + 1].secondsFromStart - ordered[i].secondsFromStart
            guard dt > 0 else { continue }
            metres += (kph / 3.6) * Double(dt)   // (m/s) × s
        }
        return metres
    }

    /// Whole seconds elapsed since `start(...)`, measured from the monotonic
    /// start instant. Unlike `elapsedSeconds` (which only advances when metrics
    /// arrive via `ingest`), this reflects real time on demand, so a UI timer can
    /// tick from a periodic clock even while the trainer is silent.
    public func elapsed(at instant: ContinuousClock.Instant = ContinuousClock.now) -> Int {
        guard isRecording else { return elapsedSeconds }
        return max(0, Int(startInstant.duration(to: instant) / .seconds(1)))
    }

    public func start(ftp: Int, zone: PowerZone, now: Date = Date(),
                      clock: ContinuousClock.Instant = ContinuousClock.now) {
        self.ftp = ftp
        self.zone = zone
        self.startedAt = now
        self.startInstant = clock
        self.samplesBySecond = [:]
        self.intervalRuns = []
        self.elapsedSeconds = 0
        self.isRecording = true
    }

    /// Log that an interval session ran, once it ends (completed or stopped
    /// early). The view owns the block timing — the recorder just records the
    /// finished fact — so the caller passes the second it started at and how
    /// long it actually ran. No-op when not recording, so a stray call after
    /// `finish()` can't append. Runs are kept in start order for the summary.
    public func recordInterval(_ session: IntervalSession, startedAtSecond: Int, actualSeconds: Int) {
        guard isRecording else { return }
        intervalRuns.append(IntervalRun(session: session,
                                        startedAtSecond: startedAtSecond,
                                        actualSeconds: actualSeconds))
    }

    /// Fold a live metrics snapshot into the current second's sample.
    public func ingest(_ metrics: RideMetrics,
                       at instant: ContinuousClock.Instant = ContinuousClock.now) {
        guard isRecording else { return }
        let second = Int(startInstant.duration(to: instant) / .seconds(1))
        guard second >= 0 else { return }

        var sample = samplesBySecond[second] ?? RideSample(secondsFromStart: second)
        if let p = metrics.powerW { sample.powerW = p }
        if let c = metrics.cadenceRpm { sample.cadenceRpm = c }
        if let s = metrics.speedKph { sample.speedKph = s }
        if let hr = metrics.heartRateBpm { sample.heartRateBpm = hr }
        // The meter's watts are assigned outright, nil included — unlike the
        // fields above, which skip a nil so a reading that carries only *some*
        // fields doesn't wipe the rest. Those sensors stream continuously, so
        // their nil only ever means "not in this frame". The meter's doesn't: a
        // quiet crank sends nothing, and `SensorHub` expires the stale value to
        // nil (see `RideMetrics.powerMeterW`). Skipping that nil would let the
        // second keep its last wattage, and the 1 Hz re-ingest would bank
        // fabricated leg power through every coast. nil means "no live reading".
        sample.powerMeterW = metrics.powerMeterW
        // R-R accumulates within the second (multiple notifications, several beats
        // each) rather than overwriting — every interval matters for HRV.
        if let rr = metrics.rrIntervalsSec, !rr.isEmpty {
            sample.rrIntervalsSec = (sample.rrIntervalsSec ?? []) + rr
        }
        samplesBySecond[second] = sample

        elapsedSeconds = max(elapsedSeconds, second + 1)
    }

    /// Stop recording and return the immutable recording. Duration is the
    /// wall-clock elapsed time captured just before we flip `isRecording` off
    /// (after that, `elapsed()` returns the frozen `elapsedSeconds`).
    @discardableResult
    public func finish(at instant: ContinuousClock.Instant = ContinuousClock.now) -> RideRecording {
        let duration = elapsed(at: instant)
        isRecording = false
        elapsedSeconds = duration
        let ordered = samplesBySecond.values.sorted { $0.secondsFromStart < $1.secondsFromStart }
        return RideRecording(ftp: ftp, zone: zone, startedAt: startedAt,
                             samples: ordered, durationSeconds: duration,
                             intervalRuns: intervalRuns)
    }
}
