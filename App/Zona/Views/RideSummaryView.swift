import Charts
import SwiftData
import SwiftUI
import ZonaKit

/// One ride's summary: headline time-in-zone, the key power stats, and a
/// power-vs-time chart with the target zone band shaded.
struct RideSummaryView: View {
    let ride: Ride
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var strava: StravaUploadModel?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                TimeInZoneHeadline(ride: ride)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    Stat(label: "Duration", value: durationText)
                    Stat(label: "Distance", value: distanceText)
                    Stat(label: "Avg HR", value: "\(ride.avgHeartRate) bpm")
                    Stat(label: "Max HR", value: "\(ride.maxHeartRate) bpm")
                    // HRV (RMSSD) — "—" when the strap reported too few R-R
                    // beats (or none), never a fabricated 0.
                    Stat(label: "HRV (RMSSD)",
                         value: ride.hrvRMSSDms.map { "\($0) ms" } ?? "—")
                    Stat(label: "Avg power", value: "\(ride.avgPowerW) W")
                    Stat(label: "Normalized", value: "\(ride.normalizedPowerW) W")
                    Stat(label: "Max power", value: "\(ride.maxPowerW) W")
                    Stat(label: "Total Time in \(ride.zone.shortName) (power)",
                         value: minutesSeconds(ride.timeInZoneSec))
                }
                .padding(.horizontal)

                PowerChart(ride: ride)
                    .frame(height: 220)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(ride.date.formatted(date: .abbreviated, time: .shortened))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let strava {
                ToolbarItem {
                    StravaButton(model: strava, ride: ride, context: modelContext)
                }
            }
            if let url = exportURL {
                ToolbarItem {
                    // Exports a .tcx the user can send to Strava (or Files /
                    // AirDrop / mail). ShareLink works on iOS and macOS.
                    ShareLink(item: url) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Ride", systemImage: "trash")
                }
            }
        }
        // Write the .tcx once when the summary opens, not on every re-render.
        .task(id: ride.id) {
            exportURL = try? ride.writeTCXTempFile()
            if strava == nil { strava = StravaUploadModel(ride: ride) }
        }
        .alert("Delete this ride?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: deleteRide)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete? This can't be undone.")
        }
    }

    private func deleteRide() {
        modelContext.delete(ride)
        try? modelContext.save()
        dismiss()
    }

    private var durationText: String {
        let s = ride.durationSec
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Simulated ride distance (trainer speed integrated), in km.
    private var distanceText: String {
        String(format: "%.1f km", ride.distanceMeters / 1000)
    }

    private func minutesSeconds(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Headline leads with time in the target HR zone — the metric that matters now
/// that zones are HR-based.
private struct TimeInZoneHeadline: View {
    let ride: Ride

    var body: some View {
        VStack(spacing: 4) {
            Text(formatted(ride.timeInHRZoneSec))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
            Text("time in \(ride.hrZone.shortName) heart-rate zone")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("\(Int((ride.timeInHRZoneFraction * 100).rounded()))% of \(formatted(ride.durationSec))")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private func formatted(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Toolbar control for uploading the ride to Strava. Its label and action follow
/// the upload state machine: connect-and-upload when idle, a spinner while
/// working, "View on Strava" once uploaded (or a duplicate), and a retry with an
/// error alert on failure. Hidden entirely when no Strava credentials are built
/// in (`.unavailable`).
private struct StravaButton: View {
    @Bindable var model: StravaUploadModel
    let ride: Ride
    let context: ModelContext
    @State private var showError = false

    var body: some View {
        Group {
            switch model.state {
            case .unavailable:
                EmptyView()
            case .idle, .failed:
                Button { Task { await model.upload(ride: ride, context: context) } } label: {
                    Label("Upload to Strava", systemImage: "arrow.up.circle")
                }
            case .authorizing, .uploading:
                ProgressView()
            case .uploaded, .duplicate:
                Button { model.openOnStrava() } label: {
                    Label("View on Strava", systemImage: "checkmark.circle.fill")
                }
            }
        }
        .onChange(of: isFailed) { _, failed in showError = failed }
        .alert("Strava upload failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let message) = model.state { Text(message) }
        }
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
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

/// Heart rate and power over time, with the target HR-zone band shaded. HR is
/// the headline series (zones are HR-based); power is shown lighter for context.
private struct PowerChart: View {
    let ride: Ride

    private var samples: [RideSampleModel] {
        (ride.samples ?? []).sorted { $0.secondsFromStart < $1.secondsFromStart }
    }

    var body: some View {
        let hrBand = HRZoneEngine(lthr: ride.lthr).bpmRange(for: ride.hrZone)

        Chart {
            RectangleMark(
                yStart: .value("Low", hrBand.lowerBound),
                yEnd: .value("High", hrBand.upperBound)
            )
            .foregroundStyle(.green.opacity(0.12))

            ForEach(samples, id: \.secondsFromStart) { sample in
                if let power = sample.powerW {
                    LineMark(
                        x: .value("Time", sample.secondsFromStart),
                        y: .value("Value", power),
                        series: .value("Series", "Power (W)")
                    )
                    .foregroundStyle(.blue.opacity(0.45))
                    .interpolationMethod(.monotone)
                }
                if let hr = sample.heartRateBpm {
                    LineMark(
                        x: .value("Time", sample.secondsFromStart),
                        y: .value("Value", hr),
                        series: .value("Series", "Heart rate (bpm)")
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale([
            "Heart rate (bpm)": Color.red,
            "Power (W)": Color.blue.opacity(0.45)
        ])
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("bpm / watts")
    }
}
