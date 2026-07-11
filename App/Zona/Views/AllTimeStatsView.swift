import Charts
import SwiftData
import SwiftUI
import ZonaKit

/// All-time rollup across every saved ride: totals, current/longest streak,
/// personal bests, and a weekly trend of time spent in the target HR zone.
/// Reuses `HistoryView`'s `@Query` shape so it stays live as rides are added
/// or deleted, then hands the mapped rides to ZonaKit's pure reducer.
struct AllTimeStatsView: View {
    @Query(sort: \Ride.date) private var rides: [Ride]

    private var stats: RideHistoryStats {
        RideHistoryStats.compute(from: rides.map(\.historyEntry))
    }

    var body: some View {
        Group {
            if rides.isEmpty {
                ContentUnavailableView(
                    "No rides yet",
                    systemImage: "chart.bar",
                    description: Text("Finish a ride and its stats will show up here.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            Stat(label: "Rides", value: "\(stats.rideCount)")
                            Stat(label: "Total time", value: durationText(stats.totalDurationSec))
                            Stat(label: "Total distance", value: distanceText(stats.totalDistanceMeters))
                            Stat(label: "Time in zone", value: percentText(stats.timeInHRZoneFraction))
                            Stat(label: "Current streak", value: dayCountText(stats.currentStreakDays))
                            Stat(label: "Longest streak", value: dayCountText(stats.longestStreakDays))
                            Stat(label: "Longest ride", value: minutesSeconds(stats.longestRideDurationSec))
                            Stat(label: "Best avg power", value: "\(stats.bestAvgPowerW) W")
                        }
                        .padding(.horizontal)

                        // A trend needs at least two weeks to show a line.
                        if stats.weeklyTotals.count > 1 {
                            WeeklyTrendChart(weeks: stats.weeklyTotals)
                                .frame(height: 180)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle("All-Time Stats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func minutesSeconds(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func distanceText(_ meters: Double) -> String {
        String(format: "%.1f km", meters / 1000)
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func dayCountText(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Weekly minutes spent in the target HR zone, oldest week first.
private struct WeeklyTrendChart: View {
    let weeks: [WeeklyRideStats]

    var body: some View {
        Chart(weeks) { week in
            BarMark(
                x: .value("Week", week.weekStart, unit: .weekOfYear),
                y: .value("Minutes in zone", week.totalTimeInHRZoneSec / 60)
            )
            .foregroundStyle(.green)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                AxisGridLine()
            }
        }
        .chartYAxisLabel("min in zone")
    }
}

/// Builds an in-memory store seeded with a handful of rides so the preview
/// renders with real numbers instead of the empty state. Dates are relative to
/// now so the current-streak logic (which keys off "today") lights up: rides
/// today, yesterday, and the day before make a 3-day current streak, plus two
/// rides in a prior week so the weekly trend chart has more than one bar.
@MainActor private func seededStatsContainer() -> ModelContainer {
    let container = try! ModelContainer(
        for: Ride.self, RideSampleModel.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let cal = Calendar.current
    func daysAgo(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: .now))!
            .addingTimeInterval(12 * 3600) // midday, clear of day boundaries
    }
    // (daysAgo, durationSec, distanceMeters, avgPowerW, timeInHRZoneSec)
    let seed: [(Int, Int, Double, Int, Int)] = [
        (0,  1_800, 10_000, 150,  900),   // today
        (1,  2_400, 13_500, 165, 1_800),  // yesterday — best avg power, longest ride
        (2,  1_500,  8_200, 140,  450),
        (9,  2_100, 11_800, 155, 1_400),  // prior week
        (11, 1_200,  6_500, 148,  600),   // prior week
    ]
    for (ago, dur, dist, power, inZone) in seed {
        container.mainContext.insert(
            Ride(date: daysAgo(ago), durationSec: dur, avgPowerW: power,
                 distanceMeters: dist, timeInHRZoneSec: inZone)
        )
    }
    return container
}

#Preview {
    NavigationStack {
        AllTimeStatsView()
    }
    .modelContainer(seededStatsContainer())
}
