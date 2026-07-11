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
                        avgPowerW: Int = 150, timeInHRZoneSec: Int = 900,
                        secondsPerHRZone: [Int: Int] = [:]) -> RideHistoryEntry {
        RideHistoryEntry(date: day(d, hour: hour), durationSec: durationSec, distanceMeters: distanceMeters,
                          avgPowerW: avgPowerW, timeInHRZoneSec: timeInHRZoneSec,
                          secondsPerHRZone: secondsPerHRZone)
    }

    @Test func emptyHistoryIsAllZero() {
        #expect(RideHistoryStats.compute(from: []) == .empty)
    }

    @Test func totalsSumAcrossRides() {
        let entries = [
            entry(day: 1, durationSec: 1800, distanceMeters: 10_000, timeInHRZoneSec: 900),
            entry(day: 2, durationSec: 2400, distanceMeters: 12_000, timeInHRZoneSec: 1200)
        ]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc)
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
        let stats = RideHistoryStats.compute(from: entries, calendar: utc)
        #expect(stats.longestRideDurationSec == 3600)
        #expect(stats.bestAvgPowerW == 200)
        #expect(abs(stats.bestTimeInHRZoneFraction - 1.0) < 0.0001)
    }

    @Test func perZoneSecondsSumPerZoneAcrossRides() {
        let entries = [
            entry(day: 1, secondsPerHRZone: [1: 100, 2: 300, 3: 50]),
            entry(day: 2, secondsPerHRZone: [2: 200, 3: 150, 5: 40])
        ]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc)
        #expect(stats.secondsPerHRZone == [1: 100, 2: 500, 3: 200, 5: 40])
        // Zone 4 was never ridden, so it's absent (not a zero bucket).
        #expect(stats.secondsPerHRZone[4] == nil)
    }

    @Test func perZoneSecondsEmptyWhenNoHRSamples() {
        let stats = RideHistoryStats.compute(from: [entry(day: 1)], calendar: utc)
        #expect(stats.secondsPerHRZone.isEmpty)
    }

    // MARK: Weekly totals

    @Test func weeklyTotalsBucketByMondayStartWeekOldestFirst() {
        // July 2026: Mon 6 – Sun 12 is one week; Mon 13 – Sun 19 the next.
        let entries = [
            entry(day: 8, durationSec: 1800, timeInHRZoneSec: 900),   // Wed, week of 6th
            entry(day: 9, durationSec: 1800, timeInHRZoneSec: 600),   // Thu, week of 6th
            entry(day: 15, durationSec: 1800, timeInHRZoneSec: 300)   // Wed, week of 13th
        ]
        let stats = RideHistoryStats.compute(from: entries, calendar: utc)
        #expect(stats.weeklyTotals.count == 2)
        #expect(stats.weeklyTotals[0].rideCount == 2)
        #expect(stats.weeklyTotals[0].totalTimeInHRZoneSec == 1500)
        #expect(stats.weeklyTotals[1].rideCount == 1)
        #expect(stats.weeklyTotals[1].totalTimeInHRZoneSec == 300)
        #expect(stats.weeklyTotals[0].weekStart < stats.weeklyTotals[1].weekStart)
    }
}
