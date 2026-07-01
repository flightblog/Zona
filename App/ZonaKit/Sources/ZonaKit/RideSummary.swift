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

    public init(durationSeconds: Int,
                averagePowerW: Int,
                maxPowerW: Int,
                normalizedPowerW: Int,
                timeInZoneSeconds: Int) {
        self.durationSeconds = durationSeconds
        self.averagePowerW = averagePowerW
        self.maxPowerW = maxPowerW
        self.normalizedPowerW = normalizedPowerW
        self.timeInZoneSeconds = timeInZoneSeconds
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
            timeInZoneSeconds: inZone
        )
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
