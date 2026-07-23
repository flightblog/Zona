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

                // Total ride time beside time spent in the target HR zone, the
                // same matched pair the live ride screen shows at its top — so a
                // ride reads the same during and after. "In zone" is the persisted
                // HR-in-target-zone figure the headline above expands on, not the
                // power-zone total in the grid below.
                HStack(spacing: 28) {
                    LabelledTime(label: "Total", time: durationText)
                    LabelledTime(label: "In zone",
                                 time: minutesSeconds(ride.timeInHRZoneSec),
                                 tint: .green)
                }

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

                // Crank-meter watts, only for rides ridden with a SRAM/Quarq
                // paired. Grouped in its own section rather than mixed into the
                // trainer stats above — it reads a few watts higher by design,
                // and the trainer remains what the zone math and the export use.
                if ride.avgPowerMeterW != nil || ride.normalizedPowerMeterW != nil || ride.maxPowerMeterW != nil {
                    PowerMeterStats(ride: ride)
                        .padding(.horizontal)
                }

                // Interval review — only for rides that actually ran a session.
                if !ride.intervalRuns.isEmpty {
                    IntervalReview(runs: ride.intervalRuns, ftp: ride.ftp)
                        .padding(.horizontal)
                }

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
/// that zones are HR-based. Names the band and the model it came from (WHOOP's
/// HRR bands or the manual LTHR ones), so a ride scored under one model isn't
/// misread against the other after the rider connects or disconnects WHOOP.
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
            Text(bandText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// e.g. "134–148 bpm · WHOOP zones" / "136–142 bpm · LTHR 160".
    private var bandText: String {
        let band = ride.zoning.bpmRange(for: ride.hrZone)
        let source = ride.zoning.isWhoop ? "WHOOP zones" : "LTHR \(ride.lthr)"
        return "\(band.lowerBound)–\(band.upperBound) bpm · \(source)"
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

/// SRAM/Quarq crank-power-meter stats, grouped separately from the trainer's
/// own power stats above — a labelled section rather than stats mixed into the
/// main grid, since the meter reads a few watts higher by design and only the
/// trainer feeds the zone math and export.
private struct PowerMeterStats: View {
    let ride: Ride

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Power Meter")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                if let avgLeg = ride.avgPowerMeterW {
                    Stat(label: "Avg leg power", value: "\(avgLeg) W")
                }
                if let npLeg = ride.normalizedPowerMeterW {
                    Stat(label: "Normalized leg power", value: "\(npLeg) W")
                }
                if let maxLeg = ride.maxPowerMeterW {
                    Stat(label: "Max leg power", value: "\(maxLeg) W")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Review of the interval sessions that ran during the ride. One card per run
/// (rides usually have just one, but stacking supports several): the session's
/// name and prescription, the work/rest steps with their target watts, and how
/// much of it the rider actually completed. Only rendered when there was at
/// least one run — see the guard at the call site.
private struct IntervalReview: View {
    let runs: [IntervalRun]
    /// The ride's FTP, so each step's target watts can be shown the same way ERG
    /// held them (`ZoneEngine.steadyTarget`) — the runs store zones, not watts.
    let ftp: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Intervals")
                .font(.headline)
            ForEach(runs) { run in
                IntervalRunCard(run: run, ftp: ftp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One run's card: title + planned prescription, a work and a rest row with
/// target watts, and a completed / stopped-early footer with actual vs planned
/// time.
private struct IntervalRunCard: View {
    let run: IntervalRun
    let ftp: Int

    private var engine: ZoneEngine { ZoneEngine(ftp: ftp) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.session.name).font(.subheadline.weight(.semibold))
                Text(run.session.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                StepRow(label: "Work", step: run.session.work, engine: engine, tint: .orange)
                StepRow(label: "Rest", step: run.session.rest, engine: engine, tint: .blue)
            }

            HStack(spacing: 6) {
                Image(systemName: run.completed ? "checkmark.circle.fill" : "stop.circle.fill")
                    .foregroundStyle(run.completed ? .green : .secondary)
                Text(run.completed
                     ? "Completed · \(mmss(run.actualSeconds))"
                     : "Stopped early · \(mmss(run.actualSeconds)) of \(mmss(run.session.totalDurationSeconds))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func mmss(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// One work/rest step: a tinted zone chip, the step's duration, and the target
/// watts ERG held for it (mid-band for the zone at the ride's FTP).
private struct StepRow: View {
    let label: String
    let step: IntervalStep
    let engine: ZoneEngine
    let tint: Color

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, alignment: .leading)
            Text(step.zone.shortName)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(tint.opacity(0.15), in: Capsule())
            Spacer()
            Text("\(step.durationSeconds)s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(engine.steadyTarget(for: step.zone)) W")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }
}

/// One labelled mm:ss readout: the time over a small uppercase caption, matching
/// the live ride screen's Total / In-zone pair so the two screens read alike.
private struct LabelledTime: View {
    let label: String
    let time: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 2) {
            Text(time)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// Heart rate and power over time on two independent scales — watts on the LEFT
/// axis, BPM on the RIGHT — with the target HR-zone band shaded. Matches the live
/// ride screen's dual-axis chart so a ride reads the same during and after.
///
/// Swift Charts plots every mark against one shared Y-domain, so the second axis
/// is faked the standard way: watts plot in natural units and own the left axis;
/// BPM (both the heart-rate line and the shaded zone band) is scaled into the
/// watts domain before plotting, then the right axis is relabelled back to real
/// BPM. Ranges auto-fit the ride's own data since a saved ride's full extent is
/// known up front.
private struct PowerChart: View {
    let ride: Ride

    /// At most this many points reach Charts. A `LineMark` per second makes a
    /// long ride thousands of marks — the summary (and the History list that
    /// pushes into it) then lag badly on open. See `downsampled(to:)`.
    private let maxPoints = 200

    private var hrBand: ClosedRange<Int> {
        ride.zoning.bpmRange(for: ride.hrZone)
    }

    /// Watts axis range: 0 to a little past the ride's peak power.
    private func wattRange(_ points: [ChartPoint]) -> ClosedRange<Double> {
        let peak = points.compactMap(\.watts).max() ?? 0
        return 0...max(100, peak * 1.1)
    }

    /// BPM axis range: padded past the ride's HR extremes, and always wide enough
    /// to contain the shaded target band even if HR never reached it.
    private func bpmRange(_ points: [ChartPoint], band: ClosedRange<Int>) -> ClosedRange<Double> {
        let hrs = points.compactMap(\.bpm)
        let lo = min(hrs.min() ?? Double(band.lowerBound), Double(band.lowerBound))
        let hi = max(hrs.max() ?? Double(band.upperBound), Double(band.upperBound))
        // Guard against a zero-width span (a ride with a single flat HR value).
        let paddedLo = lo - 5
        let paddedHi = hi + 5
        return paddedLo...max(paddedHi, paddedLo + 1)
    }

    var body: some View {
        // Compute the plotted points, HR band, and both axis ranges ONCE per
        // render. Previously these were computed properties, and the BPM→watts
        // scaling (called once per point and per axis label) re-read the ranges,
        // each of which re-ran the whole sort+downsample — so a long ride
        // reprocessed all its samples hundreds of times per layout pass and froze
        // the summary (and the History row that opens it). Binding here runs the
        // O(n log n) reduction exactly once.
        let points = (ride.samples ?? [])
            .sorted { $0.secondsFromStart < $1.secondsFromStart }
            .map { ChartPoint(seconds: $0.secondsFromStart,
                              watts: $0.powerW.map(Double.init),
                              bpm: $0.heartRateBpm.map(Double.init)) }
            .downsampled(to: maxPoints)
        let band = hrBand
        let wattRange = wattRange(points)
        let bpmRange = bpmRange(points, band: band)

        return Chart {
            // Target HR-zone band, mapped from BPM into the watts domain.
            RectangleMark(
                yStart: .value("Low", scaleBPMToWatts(Double(band.lowerBound), bpmRange: bpmRange, wattRange: wattRange)),
                yEnd: .value("High", scaleBPMToWatts(Double(band.upperBound), bpmRange: bpmRange, wattRange: wattRange))
            )
            .foregroundStyle(.green.opacity(0.12))

            ForEach(points, id: \.seconds) { point in
                if let power = point.watts {
                    LineMark(
                        x: .value("Time", point.seconds),
                        y: .value("Watts", power),
                        series: .value("Series", "Power (W)")
                    )
                    .foregroundStyle(.blue.opacity(0.45))
                    .interpolationMethod(.monotone)
                }
                if let hr = point.bpm {
                    LineMark(
                        x: .value("Time", point.seconds),
                        y: .value("BPM", scaleBPMToWatts(hr, bpmRange: bpmRange, wattRange: wattRange)),
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
        .chartYScale(domain: wattRange)
        // Both axes share the watts domain; declare them in one block (a second
        // .chartYAxis call would replace the first rather than add to it).
        .chartYAxis {
            // Left axis: real watts.
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                if let watts = value.as(Double.self) {
                    AxisValueLabel { Text("\(Int(watts))").foregroundStyle(.blue) }
                }
            }
            // Right axis: same tick positions, relabelled from watts back to BPM.
            AxisMarks(position: .trailing) { value in
                if let watts = value.as(Double.self) {
                    AxisValueLabel {
                        Text("\(unscaleWattsToBPM(watts, bpmRange: bpmRange, wattRange: wattRange))")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .chartXAxisLabel("seconds")
    }
}

/// Project a BPM value into the watts domain so the two series can share Swift
/// Charts' single Y-axis: preserves the value's *relative* position within its
/// own range, which is what makes the relabelled right axis line up. Free
/// functions (not view methods) so the ranges are passed in explicitly and
/// computed once per render, never re-derived per call — see `PowerChart.body`
/// for why that matters.
private func scaleBPMToWatts(_ bpm: Double,
                             bpmRange: ClosedRange<Double>,
                             wattRange: ClosedRange<Double>) -> Double {
    let frac = (bpm - bpmRange.lowerBound) / (bpmRange.upperBound - bpmRange.lowerBound)
    return wattRange.lowerBound + frac * (wattRange.upperBound - wattRange.lowerBound)
}

/// Inverse of `scaleBPMToWatts`: turn a watts-domain axis tick back into the BPM
/// it represents, for relabelling the right axis.
private func unscaleWattsToBPM(_ watts: Double,
                               bpmRange: ClosedRange<Double>,
                               wattRange: ClosedRange<Double>) -> Int {
    let frac = (watts - wattRange.lowerBound) / (wattRange.upperBound - wattRange.lowerBound)
    return Int((bpmRange.lowerBound + frac * (bpmRange.upperBound - bpmRange.lowerBound)).rounded())
}
