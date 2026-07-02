import Foundation

/// Pure statistics over a ride's samples. No storage, no UI — the app renders
/// these and precomputes the summary columns for SwiftData.
public struct RideSummary: Sendable, Equatable {
    public let durationSeconds: Int
    public let averagePowerW: Int
    public let maxPowerW: Int
    public let normalizedPowerW: Int
    /// Seconds spent with instantaneous power inside the target zone's band.
    public let timeInZoneSeconds: Int
    /// Total distance in metres, integrated from the trainer's reported speed.
    /// This is *simulated* (the trainer's power→speed model on a virtual flat),
    /// not GPS — the same figure Zwift/Wahoo show for an indoor ride. 0 if no
    /// sample reported speed.
    public let distanceMeters: Double

    public init(durationSeconds: Int,
                averagePowerW: Int,
                maxPowerW: Int,
                normalizedPowerW: Int,
                timeInZoneSeconds: Int,
                distanceMeters: Double = 0) {
        self.durationSeconds = durationSeconds
        self.averagePowerW = averagePowerW
        self.maxPowerW = maxPowerW
        self.normalizedPowerW = normalizedPowerW
        self.timeInZoneSeconds = timeInZoneSeconds
        self.distanceMeters = distanceMeters
    }
}

public extension RideRecording {
    /// The fraction of ride time spent in the target zone, 0…1.
    var timeInZoneFraction: Double {
        let summary = summary()
        guard summary.durationSeconds > 0 else { return 0 }
        return Double(summary.timeInZoneSeconds) / Double(summary.durationSeconds)
    }

    /// Compute all summary stats for this recording in one pass-friendly call.
    func summary() -> RideSummary {
        let powers = samples.compactMap(\.powerW)
        let engine = ZoneEngine(ftp: ftp)
        let band = engine.wattRange(for: zone)

        let duration = samples.count
        let avg = powers.isEmpty ? 0 : Int((Double(powers.reduce(0, +)) / Double(powers.count)).rounded())
        let maxP = powers.max() ?? 0
        let np = Self.normalizedPower(powers)
        let inZone = powers.filter { band.contains($0) }.count

        return RideSummary(
            durationSeconds: duration,
            averagePowerW: avg,
            maxPowerW: maxP,
            normalizedPowerW: np,
            timeInZoneSeconds: inZone,
            distanceMeters: distanceMeters
        )
    }

    /// Total ride distance in metres, integrated from reported speed. Each
    /// sample's speed is held over the gap to the *next* sample (step
    /// integration — trainers report speed stepwise, and gaps from dropped
    /// seconds shouldn't be filled by interpolation). The final sample has no
    /// "next", so it contributes nothing (a ≤1 s tail, negligible). Samples with
    /// no speed contribute 0 for their interval.
    var distanceMeters: Double {
        let ordered = samples.sorted { $0.secondsFromStart < $1.secondsFromStart }
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

    /// Running cumulative distance in metres at each sample, aligned to
    /// `samples` sorted by time — for exporters that stamp per-trackpoint
    /// distance (e.g. TCX). Element `i` is the distance covered up to and
    /// including sample `i`'s interval.
    func cumulativeDistanceMeters() -> [Double] {
        let ordered = samples.sorted { $0.secondsFromStart < $1.secondsFromStart }
        var running = 0.0
        var out: [Double] = []
        out.reserveCapacity(ordered.count)
        for i in 0..<ordered.count {
            if i + 1 < ordered.count, let kph = ordered[i].speedKph {
                let dt = ordered[i + 1].secondsFromStart - ordered[i].secondsFromStart
                if dt > 0 { running += (kph / 3.6) * Double(dt) }
            }
            out.append(running)
        }
        return out
    }

    /// Seconds where instantaneous power fell inside `zone`'s band. Defaults to
    /// the recording's own target zone.
    func timeInZone(_ zone: PowerZone? = nil) -> Int {
        let target = zone ?? self.zone
        let band = ZoneEngine(ftp: ftp).wattRange(for: target)
        return samples.compactMap(\.powerW).filter { band.contains($0) }.count
    }

    // MARK: Heart-rate zone stats
    //
    // The recording captures HR samples but not the rider's LTHR / target HR
    // zone (those live in settings), so these take them as parameters.

    /// Seconds where heart rate fell inside `hrZone`'s band for the given LTHR.
    func timeInHRZone(_ hrZone: HRZone, lthr: Int) -> Int {
        let band = HRZoneEngine(lthr: lthr).bpmRange(for: hrZone)
        return samples.compactMap(\.heartRateBpm).filter { band.contains($0) }.count
    }

    /// Fraction of ride time (0…1) spent in the target HR zone.
    func timeInHRZoneFraction(_ hrZone: HRZone, lthr: Int) -> Double {
        guard !samples.isEmpty else { return 0 }
        return Double(timeInHRZone(hrZone, lthr: lthr)) / Double(samples.count)
    }

    /// Average heart rate across samples that reported HR.
    var averageHeartRate: Int {
        let hrs = samples.compactMap(\.heartRateBpm)
        guard !hrs.isEmpty else { return 0 }
        return Int((Double(hrs.reduce(0, +)) / Double(hrs.count)).rounded())
    }

    /// Peak heart rate across samples that reported HR (0 if none).
    var maxHeartRate: Int {
        samples.compactMap(\.heartRateBpm).max() ?? 0
    }

    /// Coggan Normalized Power: 30 s rolling average → 4th-power mean → 4th root.
    /// Below 30 samples there isn't a full window, so we fall back to the mean.
    static func normalizedPower(_ powers: [Int]) -> Int {
        guard !powers.isEmpty else { return 0 }
        let window = 30
        guard powers.count >= window else {
            return Int((Double(powers.reduce(0, +)) / Double(powers.count)).rounded())
        }

        var rollingFourthPowers: [Double] = []
        rollingFourthPowers.reserveCapacity(powers.count - window + 1)
        var windowSum = powers[0..<window].reduce(0, +)
        rollingFourthPowers.append(pow(Double(windowSum) / Double(window), 4))

        for i in window..<powers.count {
            windowSum += powers[i] - powers[i - window]
            rollingFourthPowers.append(pow(Double(windowSum) / Double(window), 4))
        }

        let meanFourth = rollingFourthPowers.reduce(0, +) / Double(rollingFourthPowers.count)
        return Int(pow(meanFourth, 0.25).rounded())
    }
}
