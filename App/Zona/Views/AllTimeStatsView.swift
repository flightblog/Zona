import Charts
import SwiftData
import SwiftUI
import ZonaKit

/// All-time rollup across every saved ride: totals, personal bests, a breakdown
/// of time spent in each HR zone, and a weekly trend of in-zone time.
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
                            Stat(label: "Longest ride", value: minutesSeconds(stats.longestRideDurationSec))
                            Stat(label: "Best avg power", value: "\(stats.bestAvgPowerW) W")
                        }
                        .padding(.horizontal)

                        // Time spent in each HR zone across all rides. Only shows
                        // once some HR was recorded (older rides may have none).
                        if !stats.secondsPerHRZone.isEmpty {
                            TimeInEachZone(secondsPerZone: stats.secondsPerHRZone)
                                .padding(.horizontal)
                        }

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

/// All-time time spent in each HR zone (Z1–Z5), one row per zone with a bar
/// sized to its share of total in-zone time. `secondsPerZone` is keyed by
/// `HRZone.rawValue`; zones with no recorded time render as an empty bar.
private struct TimeInEachZone: View {
    let secondsPerZone: [Int: Int]

    private var total: Int { secondsPerZone.values.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time in each zone")
                .font(.headline)

            ForEach(HRZone.allCases) { zone in
                let seconds = secondsPerZone[zone.rawValue] ?? 0
                let fraction = total > 0 ? Double(seconds) / Double(total) : 0
                HStack(spacing: 12) {
                    Text(zone.name)
                        .font(.subheadline)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(zoneColor(zone))
                            .frame(width: max(geo.size.width * fraction, seconds > 0 ? 4 : 0))
                            .frame(maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(height: 14)
                    .background(.quaternary.opacity(0.4), in: Capsule())
                    Text(durationText(seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Cool→warm across Z1–Z5, so the effort ramp reads at a glance.
    private func zoneColor(_ zone: HRZone) -> Color {
        switch zone {
        case .z1Recovery:  return .blue
        case .z2Endurance: return .green
        case .z3Tempo:     return .yellow
        case .z4Threshold: return .orange
        case .z5VO2Max:    return .red
        }
    }

    private func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
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
/// renders with real numbers instead of the empty state. Three rides fall in a
/// recent week and two in a prior week, so the weekly trend chart has more than
/// one bar; the varied durations/power give the personal-best tiles distinct
/// values from the totals. Each ride carries a spread of per-second HR samples
/// (LTHR 160) so the "Time in each zone" section is populated across Z1–Z5.
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
    let lthr = 160
    // A representative BPM per zone at LTHR 160 (see HRZone.upperFraction):
    // Z1 <136, Z2 136–142, Z3 143–150, Z4 151–168, Z5 >168.
    let zoneBPM = [125, 139, 147, 158, 175]

    // (daysAgo, durationSec, distanceMeters, avgPowerW, timeInHRZoneSec,
    //  seconds-per-zone Z1…Z5)
    let seed: [(Int, Int, Double, Int, Int, [Int])] = [
        (0,  1_800, 10_000, 150,  900, [200, 900, 500, 180,  20]),   // today
        (1,  2_400, 13_500, 165, 1_800, [150, 800, 900, 480,  70]),  // yesterday — best power/longest
        (2,  1_500,  8_200, 140,  450, [400, 450, 400, 220,  30]),
        (9,  2_100, 11_800, 155, 1_400, [180, 700, 800, 380,  40]),  // prior week
        (11, 1_200,  6_500, 148,  600, [300, 400, 300, 180,  20]),   // prior week
    ]
    for (ago, dur, dist, power, inZone, perZone) in seed {
        let ride = Ride(date: daysAgo(ago), durationSec: dur, avgPowerW: power,
                        distanceMeters: dist, lthr: lthr, timeInHRZoneSec: inZone)
        // Expand the per-zone counts into per-second HR samples.
        var second = 0
        var samples: [RideSampleModel] = []
        for (zoneIndex, count) in perZone.enumerated() {
            for _ in 0..<count {
                samples.append(RideSampleModel(secondsFromStart: second, heartRateBpm: zoneBPM[zoneIndex]))
                second += 1
            }
        }
        ride.samples = samples
        container.mainContext.insert(ride)
    }
    return container
}

#Preview {
    NavigationStack {
        AllTimeStatsView()
    }
    .modelContainer(seededStatsContainer())
}
