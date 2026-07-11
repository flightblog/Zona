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

    public init(date: Date, durationSec: Int, distanceMeters: Double, avgPowerW: Int, timeInHRZoneSec: Int) {
        self.date = date
        self.durationSec = durationSec
        self.distanceMeters = distanceMeters
        self.avgPowerW = avgPowerW
        self.timeInHRZoneSec = timeInHRZoneSec
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
    /// Consecutive days ridden, ending today or yesterday (today doesn't break
    /// a streak until it's over — see `compute(from:)`).
    public let currentStreakDays: Int
    /// The longest run of consecutive ridden days anywhere in history.
    public let longestStreakDays: Int
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
        currentStreakDays: 0,
        longestStreakDays: 0,
        longestRideDurationSec: 0,
        bestAvgPowerW: 0,
        bestTimeInHRZoneFraction: 0,
        weeklyTotals: []
    )

    public init(rideCount: Int,
                totalDurationSec: Int,
                totalDistanceMeters: Double,
                totalTimeInHRZoneSec: Int,
                currentStreakDays: Int,
                longestStreakDays: Int,
                longestRideDurationSec: Int,
                bestAvgPowerW: Int,
                bestTimeInHRZoneFraction: Double,
                weeklyTotals: [WeeklyRideStats]) {
        self.rideCount = rideCount
        self.totalDurationSec = totalDurationSec
        self.totalDistanceMeters = totalDistanceMeters
        self.totalTimeInHRZoneSec = totalTimeInHRZoneSec
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.longestRideDurationSec = longestRideDurationSec
        self.bestAvgPowerW = bestAvgPowerW
        self.bestTimeInHRZoneFraction = bestTimeInHRZoneFraction
        self.weeklyTotals = weeklyTotals
    }

    /// Reduce every saved ride into an all-time rollup. `calendar`/`now` are
    /// injectable so streaks (which depend on "today") are deterministic in tests.
    public static func compute(from entries: [RideHistoryEntry],
                                calendar: Calendar = .current,
                                now: Date = Date()) -> RideHistoryStats {
        guard !entries.isEmpty else { return .empty }

        let rideDays = Set(entries.map { calendar.startOfDay(for: $0.date) })
        let (current, longest) = streaks(rideDays: rideDays, calendar: calendar, now: now)

        return RideHistoryStats(
            rideCount: entries.count,
            totalDurationSec: entries.reduce(0) { $0 + $1.durationSec },
            totalDistanceMeters: entries.reduce(0) { $0 + $1.distanceMeters },
            totalTimeInHRZoneSec: entries.reduce(0) { $0 + $1.timeInHRZoneSec },
            currentStreakDays: current,
            longestStreakDays: longest,
            longestRideDurationSec: entries.map(\.durationSec).max() ?? 0,
            bestAvgPowerW: entries.map(\.avgPowerW).max() ?? 0,
            bestTimeInHRZoneFraction: entries.map(\.timeInHRZoneFraction).max() ?? 0,
            weeklyTotals: weeklyTotals(entries: entries, calendar: calendar)
        )
    }

    /// `rideDays` holds each ridden calendar day once (via `calendar.startOfDay`),
    /// so consecutive entries in sorted order differ by whole days — safe to
    /// diff with `dateComponents` across DST without drifting.
    private static func streaks(rideDays: Set<Date>, calendar: Calendar, now: Date) -> (current: Int, longest: Int) {
        guard !rideDays.isEmpty else { return (0, 0) }

        let sorted = rideDays.sorted()
        var longest = 1
        var run = 1
        for i in 1..<sorted.count {
            let gap = calendar.dateComponents([.day], from: sorted[i - 1], to: sorted[i]).day ?? 0
            if gap == 1 {
                run += 1
            } else {
                longest = max(longest, run)
                run = 1
            }
        }
        longest = max(longest, run)

        // Walk back from today while consecutive; a day not yet ridden doesn't
        // break the streak until it's over, so try yesterday first if today's
        // ride hasn't happened.
        let today = calendar.startOfDay(for: now)
        var cursor = today
        if !rideDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return (0, longest) }
            cursor = yesterday
        }
        guard rideDays.contains(cursor) else { return (0, longest) }

        var current = 0
        while rideDays.contains(cursor) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return (current, longest)
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
