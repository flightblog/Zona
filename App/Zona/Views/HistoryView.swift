import SwiftData
import SwiftUI
import ZonaKit

/// List of past rides, newest first, with a time-in-zone badge. Tap for the
/// full summary. Delete via the Edit button, swipe (iOS), or the row's
/// context menu — each routes through a confirmation prompt so a ride isn't
/// destroyed by accident.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Ride.date, order: .reverse) private var rides: [Ride]

    /// Rides pending deletion, held until the user confirms.
    @State private var pendingDeletion: [Ride] = []

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
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDeletion = [ride]
                            } label: {
                                Label("Delete Ride", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: requestDelete)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !rides.isEmpty {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                #endif
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: confirmDelete)
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var confirmationTitle: String {
        pendingDeletion.count == 1
            ? "Delete this ride?"
            : "Delete \(pendingDeletion.count) rides?"
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeletion.isEmpty },
            set: { if !$0 { pendingDeletion = [] } }
        )
    }

    private func requestDelete(_ offsets: IndexSet) {
        pendingDeletion = offsets.map { rides[$0] }
    }

    private func confirmDelete() {
        for ride in pendingDeletion {
            modelContext.delete(ride)
        }
        try? modelContext.save()
        pendingDeletion = []
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
