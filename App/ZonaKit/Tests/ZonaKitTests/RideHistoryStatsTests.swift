import Foundation
import Testing
@testable import ZonaKit

@Suite("Ride history stats")
struct RideHistoryStatsTests {
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// July 2026 dates, all Wednesdays or later in that week — days are far
    /// enough from calendar/DST edges to keep the math obviously correct.
    private func day(_ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    private func entry(day d: Int, hour: Int = 12, durationSec: Int = 1800, distanceMeters: Double = 10_000,
                        avgPowerW: Int = 150, timeInHRZoneSec: Int = 900) -> RideHistoryEntry {
        RideHistoryEntry(date: day(d, hour: hour), durationSec: durationSec, distanceMeters: distanceMeters,
                          avgPowerW: avgPowerW, timeInHRZoneSec: timeInHRZoneSec)
    }

    @Test func emptyHistoryIsAllZero() {
        #expect(RideHistoryStats.compute(from: []) == .empty)
    }

    @Test func totalsSumAcrossRides() {
        let entries = [
            entry(day: 1, durationSec: 1800, distanceMeters: 10_000, timeInHRZoneSec: 900),
            entry(day: 2, durationSec: 2400, distanceMeters: 12_000, timeInHRZoneSec: 1200)
        ]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc, now: day(2))
        #expect(stats.rideCount == 2)
        #expect(stats.totalDurationSec == 4200)
        #expect(stats.totalDistanceMeters == 22_000)
        #expect(stats.totalTimeInHRZoneSec == 2100)
        #expect(abs(stats.timeInHRZoneFraction - 2100.0 / 4200.0) < 0.0001)
    }

    @Test func personalBestsPickMaxAcrossRides() {
        let entries = [
            entry(day: 1, durationSec: 1800, avgPowerW: 140, timeInHRZoneSec: 900),   // 50%
            entry(day: 2, durationSec: 3600, avgPowerW: 200, timeInHRZoneSec: 3600)   // 100%, longest
        ]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc, now: day(2))
        #expect(stats.longestRideDurationSec == 3600)
        #expect(stats.bestAvgPowerW == 200)
        #expect(abs(stats.bestTimeInHRZoneFraction - 1.0) < 0.0001)
    }

    // MARK: Streaks

    @Test func consecutiveDaysBuildACurrentStreak() {
        // Rode days 1,2,3; "now" is day 3 → 3-day current streak.
        let entries = [entry(day: 1), entry(day: 2), entry(day: 3)]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc, now: day(3))
        #expect(stats.currentStreakDays == 3)
        #expect(stats.longestStreakDays == 3)
    }

    @Test func todayNotYetRiddenDoesNotBreakStreak() {
        // Rode days 1,2; "now" is day 3 (no ride yet today) → streak still 2,
        // counted from yesterday.
        let entries = [entry(day: 1), entry(day: 2)]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc, now: day(3))
        #expect(stats.currentStreakDays == 2)
    }

    @Test func gapOfTwoOrMoreDaysEndsCurrentStreak() {
        // Last ride was day 1; "now" is day 3 → today and yesterday both
        // unridden, so the streak is over.
        let entries = [entry(day: 1)]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc, now: day(3))
        #expect(stats.currentStreakDays == 0)
    }

    @Test func longestStreakSurvivesAfterCurrentStreakEnds() {
        // A 3-day streak (1,2,3), a gap, then a lone ride on day 10. "now" is
        // day 12 → current streak is 0, but longest streak remembers the 3.
        let entries = [entry(day: 1), entry(day: 2), entry(day: 3), entry(day: 10)]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc, now: day(12))
        #expect(stats.currentStreakDays == 0)
        #expect(stats.longestStreakDays == 3)
    }

    @Test func multipleRidesOnSameDayCountOnceTowardStreak() {
        let entries = [entry(day: 1, hour: 8), entry(day: 1, hour: 18), entry(day: 2)]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc, now: day(2))
        #expect(stats.rideCount == 3)
        #expect(stats.currentStreakDays == 2)
    }

    // MARK: Weekly totals

    @Test func weeklyTotalsBucketByMondayStartWeekOldestFirst() {
        // July 2026: Mon 6 – Sun 12 is one week; Mon 13 – Sun 19 the next.
        let entries = [
            entry(day: 8, durationSec: 1800, timeInHRZoneSec: 900),   // Wed, week of 6th
            entry(day: 9, durationSec: 1800, timeInHRZoneSec: 600),   // Thu, week of 6th
            entry(day: 15, durationSec: 1800, timeInHRZoneSec: 300)   // Wed, week of 13th
        ]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc, now: day(15))
        #expect(stats.weeklyTotals.count == 2)
        #expect(stats.weeklyTotals[0].rideCount == 2)
        #expect(stats.weeklyTotals[0].totalTimeInHRZoneSec == 1500)
        #expect(stats.weeklyTotals[1].rideCount == 1)
        #expect(stats.weeklyTotals[1].totalTimeInHRZoneSec == 300)
        #expect(stats.weeklyTotals[0].weekStart < stats.weeklyTotals[1].weekStart)
    }
}
