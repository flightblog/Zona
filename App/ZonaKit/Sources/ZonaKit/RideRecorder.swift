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

    public init(secondsFromStart: Int,
                powerW: Int? = nil,
                cadenceRpm: Int? = nil,
                speedKph: Double? = nil,
                heartRateBpm: Int? = nil) {
        self.secondsFromStart = secondsFromStart
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
    }
}

/// A finished ride: the inputs it was ridden at plus its 1 Hz samples. Pure
/// value type — the app maps this into SwiftData.
public struct RideRecording: Sendable, Equatable {
    public let ftp: Int
    public let zone: PowerZone
    public let startedAt: Date
    public let samples: [RideSample]

    public init(ftp: Int, zone: PowerZone, startedAt: Date, samples: [RideSample]) {
        self.ftp = ftp
        self.zone = zone
        self.startedAt = startedAt
        self.samples = samples
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

    public init() {}

    public func start(ftp: Int, zone: PowerZone, now: Date = Date(),
                      clock: ContinuousClock.Instant = ContinuousClock.now) {
        self.ftp = ftp
        self.zone = zone
        self.startedAt = now
        self.startInstant = clock
        self.samplesBySecond = [:]
        self.elapsedSeconds = 0
        self.isRecording = true
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
        samplesBySecond[second] = sample

        elapsedSeconds = max(elapsedSeconds, second + 1)
    }

    /// Stop recording and return the immutable recording.
    @discardableResult
    public func finish() -> RideRecording {
        isRecording = false
        let ordered = samplesBySecond.values.sorted { $0.secondsFromStart < $1.secondsFromStart }
        return RideRecording(ftp: ftp, zone: zone, startedAt: startedAt, samples: ordered)
    }
}
