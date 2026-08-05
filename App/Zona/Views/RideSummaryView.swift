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
    /// Which power channel this ride's TCX carries, resolved once when the
    /// summary opens (see the `.task` below). nil until then.
    @State private var powerSource: TCXPowerSource?

    /// The ride's stored samples bridged to `ZonaKit`'s pure `RideSample`, so the
    /// interval review can slice them per step. Only built when a run exists —
    /// most rides have none, and this walks every second of the ride.
    private var intervalSamples: [RideSample] {
        guard !ride.intervalRuns.isEmpty else { return [] }
        return (ride.samples ?? []).map {
            RideSample(secondsFromStart: $0.secondsFromStart,
                       powerW: $0.powerW,
                       heartRateBpm: $0.heartRateBpm,
                       powerMeterW: $0.powerMeterW)
        }
    }

    /// Whether to caption this ride's export as trainer-sourced. Only when an
    /// upload is still ahead of the rider *and* the file would carry the
    /// trainer's estimate: hidden without Strava credentials, hidden once the
    /// ride is already on Strava (nothing left to inform), and hidden when the
    /// crank meter covered the ride, since then the export needs no caveat.
    ///
    /// Reads the resolved-once `powerSource` rather than recomputing it — that
    /// resolution walks every sample in the ride, and this is evaluated on each
    /// re-render (the same long-ride stall the chart's downsampling fixed).
    private var showsTrainerPowerExportNote: Bool {
        guard let strava, let powerSource else { return false }
        switch strava.state {
        case .unavailable, .uploaded, .duplicate: return false
        case .idle, .authorizing, .uploading, .failed: break
        }
        return powerSource == .trainer
    }

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
                    Stat(label: "Avg power", value: "\(ride.avgPowerW) W",
                         explanation: Explanation.avgPower)
                    Stat(label: "Normalized", value: "\(ride.normalizedPowerW) W",
                         explanation: Explanation.normalizedPower)
                    Stat(label: "Max power", value: "\(ride.maxPowerW) W",
                         explanation: Explanation.maxPower)
                    // "—" for rides recorded before weight tracking was added.
                    Stat(label: "Avg W/kg", value: formatted(ride.avgPowerPerKg),
                         explanation: Explanation.avgPerKg)
                    Stat(label: "Normalized W/kg", value: formatted(ride.normalizedPowerPerKg),
                         explanation: Explanation.normalizedPerKg)
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

                // Names the export's power source, but only on the fallback
                // case: an upload carrying the trainer's estimate rather than
                // crank watts is the one a rider can't tell from the summary
                // otherwise. Silent on a leg-power export, so the note stays
                // meaningful instead of becoming furniture. Strava-only —
                // the Share/TCX path is a deliberate manual act.
                if showsTrainerPowerExportNote {
                    ExportPowerSourceNote()
                        .padding(.horizontal)
                }

                // Interval review — only for rides that actually ran a session.
                if !ride.intervalRuns.isEmpty {
                    IntervalReview(runs: ride.intervalRuns,
                                   ftp: ride.ftp,
                                   samples: intervalSamples)
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
        // The export's power source is resolved here for the same reason — it
        // walks every sample, so it must not sit in a computed property.
        .task(id: ride.id) {
            exportURL = try? ride.writeTCXTempFile()
            powerSource = ride.tcxPowerSource
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

    private func formatted(_ wattsPerKg: Double?) -> String {
        wattsPerKg.map { String(format: "%.1f W/kg", $0) } ?? "—"
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

/// Passive caption naming the trainer as this ride's export power source.
/// Shown only on the fallback case (see `showsTrainerPowerExportNote`) — a
/// caption rather than a confirmation dialog, since uploading is an action the
/// rider chose deliberately and shouldn't have to defend. Reuses the same
/// drivetrain-loss vocabulary as the leg-power tiles' explanations.
private struct ExportPowerSourceNote: View {
    var body: some View {
        Label {
            Text("This ride uploads with the trainer's estimated power. "
                 + "Rides recorded with the crank meter connected upload its "
                 + "measured leg power instead, which reads a few watts higher.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
                    Stat(label: "Avg leg power", value: "\(avgLeg) W",
                         explanation: Explanation.avgLegPower)
                }
                if let npLeg = ride.normalizedPowerMeterW {
                    Stat(label: "Normalized leg power", value: "\(npLeg) W",
                         explanation: Explanation.normalizedLegPower)
                }
                if let maxLeg = ride.maxPowerMeterW {
                    Stat(label: "Max leg power", value: "\(maxLeg) W",
                         explanation: Explanation.maxLegPower)
                }
                // Both W/kg tiles divide the *meter's* watts by the ride's
                // stamped weight, so they read a little above the trainer-based
                // pair in the grid above — same physical gap as the watt tiles
                // beside them. Gated like the watt tiles, so a ride that
                // predates weight tracking drops them rather than showing "—"
                // (the main grid's trainer pair dashes instead; that section
                // always renders a fixed set of tiles, this one doesn't).
                if let avgPerKg = ride.avgPowerMeterPerKg {
                    Stat(label: "Avg leg W/kg", value: formatted(avgPerKg),
                         explanation: Explanation.avgLegPerKg)
                }
                if let npPerKg = ride.normalizedPowerMeterPerKg {
                    Stat(label: "Normalized leg W/kg", value: formatted(npPerKg),
                         explanation: Explanation.normalizedLegPerKg)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatted(_ wattsPerKg: Double) -> String {
        String(format: "%.1f W/kg", wattsPerKg)
    }
}

/// Plain-English blurbs for the summary tiles whose meaning isn't obvious from
/// the label — chiefly the average-vs-normalized pair, which read almost
/// identically on a steady ERG ride and diverge on an interval session. Kept
/// together so the average and normalized wordings stay consistent with each
/// other.
private enum Explanation {
    static let avgPower = """
        The plain average of every power reading from the trainer over the whole \
        ride. On a steady ERG ride this sits right at your hold target.
        """

    static let normalizedPower = """
        An effort-weighted average that counts hard efforts more heavily than \
        easy ones, so it reflects how hard the ride actually felt. On a steady \
        ERG ride it nearly matches Avg power; after an interval session it reads \
        higher, and the gap is a measure of how spiky the ride was.
        """

    static let maxPower = """
        The single highest watt reading from the trainer during the ride.
        """

    static let avgPerKg = """
        Avg power divided by your weight at the time of this ride — the plain \
        average of the trainer's watts per kilogram.
        """

    static let normalizedPerKg = """
        Normalized power divided by your weight at the time of this ride. Same \
        effort-weighting as Normalized, so it runs higher than Avg W/kg on a \
        ride with intervals and matches it closely on a steady one.
        """

    // The leg-power blurbs each carry the crank-vs-trainer point as well as the
    // averaging one: the first question this section raises is why its numbers
    // don't match the trainer's, and a rider reading one tile shouldn't have to
    // find the answer on another. Kept consistent with the physical explanation
    // on `RideMetrics.powerMeterW`.
    static let avgLegPower = """
        The plain average of your power meter's watts over the whole ride. Your \
        meter measures at the cranks, so it reads a few watts above the \
        trainer — that gap is drivetrain loss between the cranks and the \
        flywheel, not an error. The trainer stays the number the ride is scored \
        and uploaded on.
        """

    static let normalizedLegPower = """
        Your power meter's watts, effort-weighted so hard efforts count more \
        heavily than easy ones — the same calculation as Normalized above, run \
        on the meter instead of the trainer. Expect it a few watts above the \
        trainer's figure, which is drivetrain loss rather than an error.
        """

    static let maxLegPower = """
        The single highest watt reading from your power meter during the ride. \
        Measured at the cranks, so it sits above the trainer's max for the same \
        effort.
        """

    static let avgLegPerKg = """
        Avg leg power divided by your weight at the time of this ride. It reads \
        a little above the Avg W/kg tile further up, for the same reason the \
        watts do — that one is measured at the flywheel, this one at the cranks.
        """

    static let normalizedLegPerKg = """
        Normalized leg power divided by your weight at the time of this ride. \
        Same effort-weighting as Normalized leg power, so it runs above Avg leg \
        W/kg on a ride with intervals and matches it closely on a steady one.
        """
}

private struct Stat: View {
    let label: String
    let value: String
    /// Optional plain-English explanation of what the figure means. When set, an
    /// info button sits beside the label and reveals this in a popover.
    var explanation: String?

    @State private var showExplanation = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if explanation != nil {
                    // A tap target on both platforms — `.help` alone is a
                    // macOS-only hover affordance and would be invisible on iOS.
                    // Purely decorative to VoiceOver: the whole tile is one
                    // element carrying the same explanation as its hint, so the
                    // button must not add a second stop of its own.
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            guard explanation != nil else { return }
            showExplanation = true
        }
        .help(explanation ?? "")
        .popover(isPresented: $showExplanation) {
            Text(explanation ?? "")
                .font(.callout)
                .multilineTextAlignment(.leading)
                .padding()
                .frame(idealWidth: 280)
                .presentationCompactAdaptation(.popover)
        }
        // One stop per tile, spoken "Avg power: 210 W" — the same merge the ride
        // screen's Metric tiles make (see `RideView`), so a rider swiping the
        // grid hears one stop per reading rather than two. The explanation rides
        // along as the hint instead of becoming a separately focusable button.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint(explanation ?? "")
        .accessibilityAddTraits(explanation != nil ? .isButton : [])
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
    /// The ride's samples, sliced per step to show what was actually held. Passed
    /// down whole; `IntervalAchievement` windows them to each run.
    let samples: [RideSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Intervals")
                .font(.headline)
            ForEach(runs) { run in
                IntervalRunCard(run: run, ftp: ftp, samples: samples)
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

    private let engine: ZoneEngine
    /// Sliced ONCE, in `init` — not as a computed property. `perStep` scans every
    /// sample in the ride, and a computed property would re-run that on each
    /// layout pass; that exact mistake froze the summary on long rides when the
    /// chart's points were computed per-render (see `PowerChart`'s note). Already
    /// filtered to the rows worth drawing.
    private let rows: [IntervalStepAchievement]
    private let showsLegPower: Bool

    init(run: IntervalRun, ftp: Int, samples: [RideSample]) {
        self.run = run
        self.ftp = ftp
        self.engine = ZoneEngine(ftp: ftp)
        let achieved = IntervalAchievement.perStep(run: run, samples: samples)
            .filter { !$0.isEmpty }
        self.rows = achieved
        self.showsLegPower = achieved.contains { $0.avgPowerMeterW != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.session.name).font(.subheadline.weight(.semibold))
                Text(run.session.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // What was prescribed and what was held, one row per step. A
            // free-form session can be any shape, so the old fixed Work/Rest
            // pair of `StepRow`s no longer describes it — the table carries each
            // step's zone and target itself. Skipped for a run with no usable
            // samples (sensors silent), leaving just the name + summary line.
            if !rows.isEmpty {
                AchievedTable(rows: rows, engine: engine, showsLegPower: showsLegPower)
            } else {
                // No samples to score against: still show what was prescribed.
                VStack(spacing: 6) {
                    ForEach(Array(run.session.steps.enumerated()), id: \.offset) { index, step in
                        StepRow(label: "Step \(index + 1)",
                                step: step,
                                engine: engine,
                                tint: step.zone.rawValue >= PowerZone.z3Tempo.rawValue ? .orange : .blue)
                    }
                }
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

/// The achieved figures, one row per work/rest step of each repeat — what the
/// rider actually held against the prescription listed above it.
///
/// Every column names both its **channel** and its **statistic**, because the
/// trainer and the crank meter are parallel channels that legitimately disagree
/// (the meter reads a few watts high by design), and a bare "W" or "bpm" beside
/// them invites reading one as the other's peak. So: `avg W`/`max W` are the
/// trainer's, `leg avg W` is the meter's, and HR is explicitly `avg bpm` —
/// average, not peak, since across a set it's drift that's informative while the
/// peak is mostly noise.
///
/// The leg column only appears when a crank meter was paired for at least part
/// of the run; without one the table stays three columns wide instead of showing
/// a dash per row. Missing values read "—" rather than 0: the meter expires on a
/// coast and a strap can drop, and printing 0 W would claim the rider
/// soft-pedalled when the truth is we have no reading.
private struct AchievedTable: View {
    let rows: [IntervalStepAchievement]
    /// Resolves each step's prescribed watts from its zone at the ride's FTP —
    /// the same `ZoneEngine.steadyTarget` call ERG was driven with, so the
    /// target column shows what was actually commanded.
    let engine: ZoneEngine
    let showsLegPower: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("STEP")
                    .frame(width: 96, alignment: .leading)
                Text("target").frame(maxWidth: .infinity, alignment: .trailing)
                Text("avg W").frame(maxWidth: .infinity, alignment: .trailing)
                Text("max W").frame(maxWidth: .infinity, alignment: .trailing)
                // Sits after the trainer's own pair, so the two watt columns it
                // parallels read together rather than being split by it.
                if showsLegPower {
                    Text("leg avg W").frame(maxWidth: .infinity, alignment: .trailing)
                }
                Text("avg bpm").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(rows) { row in
                HStack(spacing: 0) {
                    // Step number, its zone, and how long it ran — the
                    // prescription, since a free-form session has no work/rest
                    // alternation to label instead.
                    HStack(spacing: 4) {
                        Text("\(row.stepIndex + 1)")
                            .font(.caption.weight(.medium))
                            .frame(width: 18, alignment: .leading)
                        Text(row.zone.shortName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(row.zone.rawValue >= PowerZone.z3Tempo.rawValue
                                             ? .orange : .blue)
                        Text(mmss(row.seconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 96, alignment: .leading)

                    Text("\(engine.steadyTarget(for: row.zone))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    value(row.avgPowerW)
                    value(row.maxPowerW)
                    if showsLegPower { value(row.avgPowerMeterW) }
                    value(row.avgHeartRateBpm)
                }
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Achieved per step")
    }

    private func mmss(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func value(_ v: Int?) -> some View {
        Text(v.map(String.init) ?? "—")
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .trailing)
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
