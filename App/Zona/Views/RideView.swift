import SwiftData
import SwiftUI
import ZonaKit

/// Live ride screen. BPM is the target the rider is chasing and watts is the
/// lever (ERG) they pull to get there, so both get an equal, glanceable arc
/// gauge side by side: each fills to show where the live value sits within its
/// band and shows a color + word + arrow cue (PUSH / HOLD / EASE) so you know
/// at a glance whether you're in target and which way to correct — without
/// relying on color alone. Cadence/speed stay small below; End ride at the
/// bottom. When the view appears we push the ERG target and start recording;
/// on End ride we save the ride to SwiftData and show its summary.
struct RideView: View {
    @Environment(TrainerController.self) private var controller
    @Environment(RideSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var recorder = RideRecorder()
    @State private var savedRide: Ride?
    /// Closed-loop HR→watts controller. Only consulted when `hrHoldEnabled`;
    /// mutable across ticks so it remembers its cooldown/breakout timers.
    @State private var hrHold = HRHoldController()

    /// Watts are held by ERG, so "in target" is a tight window around the
    /// setpoint rather than the full (wide) power-zone band.
    private let wattTolerance = 8

    var body: some View {
        VStack(spacing: 24) {
            // Tick once a second off a periodic clock so the timer advances on
            // its own, independent of whether new trainer metrics have arrived.
            // Reading `context.date` is what makes SwiftUI re-render each tick.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedText(asOf: context.date))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Two equal gauges: BPM (the target) and Watts (the lever).
            HStack(alignment: .top, spacing: 20) {
                ZoneGauge(
                    value: controller.metrics.heartRateBpm,
                    band: settings.targetHRBand,
                    label: "bpm",
                    caption: settings.hrZone.name,
                    icon: "heart.fill"
                )
                ZoneGauge(
                    value: controller.metrics.powerW,
                    band: wattBand,
                    label: "watts",
                    caption: settings.hrHoldEnabled ? "target \(wattTarget) W · AUTO" : "target \(wattTarget) W",
                    icon: "bolt.fill"
                )
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 32) {
                Metric(title: "Cadence",
                       value: controller.metrics.cadenceRpm.map { "\($0)" } ?? "—",
                       unit: "rpm")
                Metric(title: "Speed",
                       value: controller.metrics.speedKph.map { String(format: "%.1f", $0) } ?? "—",
                       unit: "km/h")
            }

            TargetAdjuster(onAdjust: manualAdjust)

            Spacer()

            Button(role: .destructive, action: endRide) {
                Text("End ride").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            // Enter ERG at the configured steady target and start recording.
            controller.setTargetPower(settings.target)
            recorder.start(ftp: settings.ftp, zone: settings.zone)
        }
        .onChange(of: controller.metrics) { _, newMetrics in
            recorder.ingest(newMetrics)
        }
        // Closed-loop HR-hold: tick once a second and let the controller nudge the
        // ERG target to keep HR in zone. Only active when the rider opted in; the
        // open-loop path above is untouched. The `.task` runs for the view's life
        // and is cancelled on End ride.
        .task {
            let clock = ContinuousClock()
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1))
                hrHoldTick()
            }
        }
        .sheet(item: $savedRide) { ride in
            NavigationStack {
                RideSummaryView(ride: ride)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { savedRide = nil }
                        }
                    }
            }
        }
    }

    /// One closed-loop control step. No-op unless auto-hold is enabled and the
    /// ride is recording. Feeds live HR + the current target into the controller
    /// and applies any adjustment via the same ERG lever the manual buttons use.
    private func hrHoldTick() {
        guard settings.hrHoldEnabled, recorder.isRecording else { return }
        let current = controller.metrics.targetW ?? settings.target
        let decision = hrHold.update(
            hr: controller.metrics.heartRateBpm,
            currentTargetW: current,
            band: settings.targetHRBand,
            wattClamp: settings.engine.wattRange(for: settings.zone),
            now: Double(recorder.elapsed())
        )
        if let newTarget = decision.newTargetW {
            controller.setTargetPower(newTarget)
            controller.note("Auto-hold: \(decision.reason)")
        }
    }

    /// Apply a manual target change and tell the HR-hold controller, so auto-hold
    /// backs off briefly instead of immediately fighting the rider's nudge.
    private func manualAdjust(to watts: Int) {
        controller.setTargetPower(watts)
        hrHold.noteManualAdjust(at: Double(recorder.elapsed()))
    }

    private func endRide() {
        let recording = recorder.finish()
        controller.stop()
        // Only persist rides that actually captured data.
        guard !recording.samples.isEmpty else { return }
        let ride = Ride.make(from: recording, lthr: settings.lthr, hrZone: settings.hrZone)
        modelContext.insert(ride)
        try? modelContext.save()
        savedRide = ride
    }

    /// Elapsed ride time as mm:ss. `asOf` is the enclosing `TimelineView`'s
    /// periodic tick — passing it in ties the recompute to the clock, so the
    /// timer keeps counting even when metrics are static.
    private func elapsedText(asOf _: Date) -> String {
        let s = recorder.isRecording ? recorder.elapsed() : recorder.elapsedSeconds
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var wattTarget: Int { controller.metrics.targetW ?? settings.target }

    private var wattBand: ClosedRange<Int> {
        (wattTarget - wattTolerance)...(wattTarget + wattTolerance)
    }
}

/// Where a live reading sits relative to its target band, and the correction it
/// implies. Drives color, arrow, and word so the cue survives a quick glance
/// and doesn't depend on color perception alone.
private enum ZoneState {
    case noData, below, inZone, above

    init(value: Int?, band: ClosedRange<Int>) {
        guard let value else { self = .noData; return }
        if value < band.lowerBound { self = .below }
        else if value > band.upperBound { self = .above }
        else { self = .inZone }
    }

    var tint: Color {
        switch self {
        case .noData: return .gray
        case .below:  return .blue    // too easy
        case .inZone: return .green
        case .above:  return .orange  // too hard
        }
    }

    /// Short verb + arrow telling the rider how to correct.
    var cue: String {
        switch self {
        case .noData: return "—"
        case .below:  return "↑ PUSH"
        case .inZone: return "✓ HOLD"
        case .above:  return "↓ EASE"
        }
    }
}

/// One circular gauge: big number in the center, ring showing where the live
/// value sits across the band (padded so you can see how far past either edge
/// you are), and a color-coded state chip beneath. Used identically for BPM and
/// watts so the two read as one system.
private struct ZoneGauge: View {
    let value: Int?
    let band: ClosedRange<Int>
    let label: String
    let caption: String
    let icon: String

    private var state: ZoneState { ZoneState(value: value, band: band) }

    /// Map the value across the band with 40% padding on each side so the ring
    /// isn't pinned to the edges the moment you're in zone — the band occupies
    /// the middle ~55% of the arc, out-of-band readings push toward the ends.
    private var fraction: Double {
        guard let value else { return 0 }
        let span = Double(max(band.upperBound - band.lowerBound, 1))
        let pad = span * 0.4
        let lo = Double(band.lowerBound) - pad
        let hi = Double(band.upperBound) + pad
        return min(max((Double(value) - lo) / (hi - lo), 0), 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(state.tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)

                VStack(spacing: 0) {
                    Image(systemName: icon)
                        .font(.callout)
                        .foregroundStyle(state.tint)
                    Text(value.map { "\($0)" } ?? "—")
                        .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)

            // State chip: color + word + arrow. Redundant cues on purpose.
            Text(state.cue)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(state.tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(state.tint.opacity(0.15), in: Capsule())

            Text("\(caption) · \(band.lowerBound)–\(band.upperBound)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack {
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("\(title) · \(unit)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Nudge the ERG target up/down mid-ride without leaving the zone screen. Routes
/// through `onAdjust` (not `setTargetPower` directly) so the parent can tell the
/// HR-hold controller a manual change happened and back off briefly.
private struct TargetAdjuster: View {
    @Environment(TrainerController.self) private var controller
    @Environment(RideSettings.self) private var settings
    let onAdjust: (Int) -> Void

    var body: some View {
        let current = controller.metrics.targetW ?? settings.target
        HStack(spacing: 16) {
            Button { onAdjust(current - 5) } label: {
                Image(systemName: "minus.circle.fill")
            }
            Text("Adjust target").font(.callout).foregroundStyle(.secondary)
            Button { onAdjust(current + 5) } label: {
                Image(systemName: "plus.circle.fill")
            }
        }
        .font(.title2)
        .buttonStyle(.plain)
    }
}

#Preview {
    RideView()
        .environment(TrainerController())
        .environment(RideSettings())
}
