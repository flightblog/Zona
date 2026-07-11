import Foundation

/// One saved ride's contribution to all-time history stats. Pure, SwiftData-free
/// — the app target maps its persisted `Ride` rows into these before calling
/// `RideHistoryStats.compute(from:)`.
public struct RideHistoryEntry: Sendable, Equatable {
    public let date: Date
    public let durationSec: Int
    public let distanceMeters: Double
    public let avgPowerW: Int
    public let timeInHRZoneSec: Int
    /// Seconds spent in each HR zone this ride, keyed by `HRZone.rawValue` (1…5),
    /// recomputed from the ride's per-second HR samples. Zones with no time are
    /// omitted; empty for rides with no HR samples.
    public let secondsPerHRZone: [Int: Int]

    public init(date: Date, durationSec: Int, distanceMeters: Double, avgPowerW: Int,
                timeInHRZoneSec: Int, secondsPerHRZone: [Int: Int] = [:]) {
        self.date = date
        self.durationSec = durationSec
        self.distanceMeters = distanceMeters
        self.avgPowerW = avgPowerW
        self.timeInHRZoneSec = timeInHRZoneSec
        self.secondsPerHRZone = secondsPerHRZone
    }

    /// Fraction of this ride spent in the target HR zone, 0…1.
    public var timeInHRZoneFraction: Double {
        durationSec > 0 ? Double(timeInHRZoneSec) / Double(durationSec) : 0
    }
}

/// One Monday-start week's rollup, for a trend chart.
public struct WeeklyRideStats: Sendable, Equatable, Identifiable {
    public let weekStart: Date
    public let rideCount: Int
    public let totalTimeInHRZoneSec: Int

    public var id: Date { weekStart }

    public init(weekStart: Date, rideCount: Int, totalTimeInHRZoneSec: Int) {
        self.weekStart = weekStart
        self.rideCount = rideCount
        self.totalTimeInHRZoneSec = totalTimeInHRZoneSec
    }
}

/// All-time rollup over every saved ride. No storage, no UI — mirrors
/// `RideSummary`'s "pure stats" shape but reduces across rides instead of
/// across one ride's samples.
public struct RideHistoryStats: Sendable, Equatable {
    public let rideCount: Int
    public let totalDurationSec: Int
    public let totalDistanceMeters: Double
    public let totalTimeInHRZoneSec: Int
    /// All-time seconds spent in each HR zone, keyed by `HRZone.rawValue` (1…5),
    /// summed across every ride's per-second HR samples. Zones never ridden are
    /// omitted.
    public let secondsPerHRZone: [Int: Int]
    public let longestRideDurationSec: Int
    public let bestAvgPowerW: Int
    public let bestTimeInHRZoneFraction: Double
    /// Oldest week first.
    public let weeklyTotals: [WeeklyRideStats]

    /// Fraction of all logged time spent in the target HR zone, 0…1.
    public var timeInHRZoneFraction: Double {
        totalDurationSec > 0 ? Double(totalTimeInHRZoneSec) / Double(totalDurationSec) : 0
    }

    public static let empty = RideHistoryStats(
        rideCount: 0,
        totalDurationSec: 0,
        totalDistanceMeters: 0,
        totalTimeInHRZoneSec: 0,
        secondsPerHRZone: [:],
        longestRideDurationSec: 0,
        bestAvgPowerW: 0,
        bestTimeInHRZoneFraction: 0,
        weeklyTotals: []
    )

    public init(rideCount: Int,
                totalDurationSec: Int,
                totalDistanceMeters: Double,
                totalTimeInHRZoneSec: Int,
                secondsPerHRZone: [Int: Int],
                longestRideDurationSec: Int,
                bestAvgPowerW: Int,
                bestTimeInHRZoneFraction: Double,
                weeklyTotals: [WeeklyRideStats]) {
        self.rideCount = rideCount
        self.totalDurationSec = totalDurationSec
        self.totalDistanceMeters = totalDistanceMeters
        self.totalTimeInHRZoneSec = totalTimeInHRZoneSec
        self.secondsPerHRZone = secondsPerHRZone
        self.longestRideDurationSec = longestRideDurationSec
        self.bestAvgPowerW = bestAvgPowerW
        self.bestTimeInHRZoneFraction = bestTimeInHRZoneFraction
        self.weeklyTotals = weeklyTotals
    }

    /// Reduce every saved ride into an all-time rollup. `calendar` is injectable
    /// so the weekly bucketing is deterministic in tests.
    public static func compute(from entries: [RideHistoryEntry],
                                calendar: Calendar = .current) -> RideHistoryStats {
        guard !entries.isEmpty else { return .empty }

        var secondsPerHRZone: [Int: Int] = [:]
        for entry in entries {
            for (zone, seconds) in entry.secondsPerHRZone {
                secondsPerHRZone[zone, default: 0] += seconds
            }
        }

        return RideHistoryStats(
            rideCount: entries.count,
            totalDurationSec: entries.reduce(0) { $0 + $1.durationSec },
            totalDistanceMeters: entries.reduce(0) { $0 + $1.distanceMeters },
            totalTimeInHRZoneSec: entries.reduce(0) { $0 + $1.timeInHRZoneSec },
            secondsPerHRZone: secondsPerHRZone,
            longestRideDurationSec: entries.map(\.durationSec).max() ?? 0,
            bestAvgPowerW: entries.map(\.avgPowerW).max() ?? 0,
            bestTimeInHRZoneFraction: entries.map(\.timeInHRZoneFraction).max() ?? 0,
            weeklyTotals: weeklyTotals(entries: entries, calendar: calendar)
        )
    }

    /// Buckets every ride into the Monday-start week it fell in.
    private static func weeklyTotals(entries: [RideHistoryEntry], calendar: Calendar) -> [WeeklyRideStats] {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2

        var buckets: [Date: (count: Int, timeInZone: Int)] = [:]
        for entry in entries {
            let weekStart = mondayFirst.dateInterval(of: .weekOfYear, for: entry.date)?.start ?? entry.date
            buckets[weekStart, default: (0, 0)].count += 1
            buckets[weekStart, default: (0, 0)].timeInZone += entry.timeInHRZoneSec
        }
        return buckets.keys.sorted().map { week in
            let bucket = buckets[week]!
            return WeeklyRideStats(weekStart: week, rideCount: bucket.count, totalTimeInHRZoneSec: bucket.timeInZone)
        }
    }
}
