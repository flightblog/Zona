import SwiftData
import SwiftUI
import ZonaKit

/// List of past rides, newest first, with a time-in-zone badge. Tap for the
/// full summary; swipe to delete.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Ride.date, order: .reverse) private var rides: [Ride]

    var body: some View {
        Group {
            if rides.isEmpty {
                ContentUnavailableView(
                    "No rides yet",
                    systemImage: "bicycle",
                    description: Text("Finish a ride and it'll show up here.")
                )
            } else {
                List {
                    ForEach(rides) { ride in
                        NavigationLink {
                            RideSummaryView(ride: ride)
                        } label: {
                            RideRow(ride: ride)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("History")
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(rides[index])
        }
        try? modelContext.save()
    }
}

private struct RideRow: View {
    let ride: Ride

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ride.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text("\(durationText) · avg \(ride.avgHeartRate) bpm")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ZoneBadge(fraction: ride.timeInHRZoneFraction, zoneShortName: ride.hrZone.shortName)
        }
        .padding(.vertical, 2)
    }

    private var durationText: String {
        String(format: "%d:%02d", ride.durationSec / 60, ride.durationSec % 60)
    }
}

private struct ZoneBadge: View {
    let fraction: Double
    let zoneShortName: String

    var body: some View {
        VStack(spacing: 0) {
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.headline.monospacedDigit())
            Text("in \(zoneShortName)")
                .font(.caption2)
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.green.opacity(0.12), in: Capsule())
    }
}
