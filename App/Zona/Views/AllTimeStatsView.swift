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

#Preview {
    NavigationStack {
        AllTimeStatsView()
    }
    .modelContainer(for: [Ride.self, RideSampleModel.self], inMemory: true)
}
