import SwiftData
import SwiftUI
import ZonaKit

/// List of past rides, newest first, with a time-in-zone badge. Tap for the
/// full summary, where a ride can be deleted (behind a confirmation alert).
struct HistoryView: View {
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
                }
            }
        }
        .navigationTitle("History")
    }
}

private struct RideRow: View {
    let ride: Ride

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ride.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text(subtitle)
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

    /// Duration + avg HR, with HRV appended only when the ride measured it — so
    /// rides from a strap that reports no R-R (or older rides) look unchanged.
    private var subtitle: String {
        var text = "\(durationText) · avg \(ride.avgHeartRate) bpm"
        if let hrv = ride.hrvRMSSDms { text += " · HRV \(hrv) ms" }
        return text
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
