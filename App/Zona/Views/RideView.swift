import SwiftData
import SwiftUI
import ZonaKit

/// Live ride screen. BPM is the target the rider is chasing and watts is the
/// lever (ERG) they pull to get there; cadence is form. All three get an equal,
/// glanceable arc gauge side by side: each fills to show where the live value
/// sits within its band and shows a color + word + arrow cue (PUSH / HOLD /
/// EASE) so you know at a glance whether you're in target and which way to
/// correct — without relying on color alone. Speed stays small below; End ride
/// at the bottom. When the view appears we push the ERG target and start
/// recording; on End ride we save the ride to SwiftData and show its summary.
struct RideView: View {
    @Environment(TrainerController.self) private var controller
    @Environment(RideSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var recorder = RideRecorder()
    @State private var savedRide: Ride?
    /// Drives the "End ride?" confirmation so a stray tap can't discard a ride.
    @State private var confirmingEnd = false
    /// The HR-zone model this ride is being ridden against, latched from settings
    /// at ride start (`.onAppear`) rather than read again at save time. The rider
    /// chases the band this view shows, so that band — not whatever settings hold
    /// when they hit End ride — is the one the ride must be scored against. A
    /// WHOOP refresh landing mid-ride would otherwise move the target under them
    /// and rescore the ride against bands they were never aiming at.
    @State private var zoning: RideHRZoning?

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
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Three equal gauges: BPM (the target), Watts (the lever), and
            // Cadence (form). Each fills to show where the live value sits in its
            // band. Cadence has no app-managed target, so it uses a fixed
            // endurance-comfortable band.
            // Bottom alignment so the dials share a baseline and the slightly
            // larger HR dial grows upward rather than hanging off a shared top.
            HStack(alignment: .bottom, spacing: 12) {
                ZoneGauge(
                    value: controller.metrics.powerW,
                    band: wattBand,
                    label: "watts",
                    caption: "target \(wattTarget) W",
                    icon: "bolt.fill"
                )
                ZoneGauge(
                    value: controller.metrics.heartRateBpm,
                    band: targetHRBand,
                    label: "bpm",
                    caption: settings.hrZone.name,
                    icon: "heart.fill",
                    // HR is the target the rider chases, so give the center dial a
                    // couple extra points over Watts/RPM to draw the eye.
                    ringSize: 120
                )
                ZoneGauge(
                    value: controller.metrics.cadenceRpm,
                    band: cadenceBand,
                    label: "rpm",
                    caption: "cadence",
                    icon: "arrow.trianglehead.clockwise"
                )
            }
            .frame(maxWidth: .infinity)

            // Which HR zone the current effort is in, on the model this ride is
            // scored against. It sits directly under the dials, above the smaller
            // Speed/Distance/SRAM line: mid-ride you're steering to a zone, not
            // reading a trend, so this belongs with the primary readouts rather
            // than below the secondary ones. (It replaced a live watts/BPM
            // time-series, which was answering a question — "how have I drifted?"
            // — better asked afterwards; the summary still plots the full ride.)
            HRZoneBar(bpm: controller.metrics.heartRateBpm, zoning: rideZoning)

            // Speed, Distance, and the secondary SRAM/Quarq readout (power +
            // cadence) all share one line. The SRAM tiles only appear when the
            // meter is connected and reporting; when it is, four tiles have to
            // fit across a phone, so the row scales its font down to keep them on
            // one line. The SRAM values are informational: none of it is
            // recorded, exported, or used by ERG (see `RideMetrics.powerMeterW`).
            HStack(spacing: 16) {
                Metric(title: "Speed",
                       value: controller.metrics.speedKph.map { String(format: "%.1f", $0) } ?? "—",
                       unit: "km/h")
                Metric(title: "Distance",
                       value: String(format: "%.2f", recorder.distanceMeters / 1000),
                       unit: "km")
                if let meterW = controller.metrics.powerMeterW {
                    Metric(title: "SRAM", value: "\(meterW)", unit: "W")
                    Metric(title: "SRAM",
                           value: controller.metrics.powerMeterCadenceRpm.map { "\($0)" } ?? "—",
                           unit: "RPM")
                }
            }
            .frame(maxWidth: .infinity)

            TargetAdjuster()

            Spacer()

            Button(role: .destructive) { confirmingEnd = true } label: {
                Text("End ride").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        // Keep the screen awake for the whole ride: it's watched, not touched,
        // so the idle timer / display sleep would otherwise blank the live dials
        // (and a locked phone can suspend the app mid-session). Tied to this
        // view's lifetime, which is exactly the live-ride window.
        .keepAwake()
        .alert("End ride?", isPresented: $confirmingEnd) {
            Button("End ride", role: .destructive, action: endRide)
            Button("Keep riding", role: .cancel) {}
        } message: {
            Text("This stops recording and saves your ride.")
        }
        .onAppear {
            // Enter ERG at the configured steady target and start recording, and
            // pin the HR-zone model for the rest of the ride.
            controller.setTargetPower(settings.target)
            recorder.start(ftp: settings.ftp, zone: settings.zone)
            zoning = settings.zoning
        }
        .onChange(of: controller.metrics) { _, newMetrics in
            recorder.ingest(newMetrics)
        }
        // Gap-free recording: re-ingest the current metrics every second so a
        // steady stretch (identical metrics → `.onChange` doesn't fire) still
        // produces a sample. Without this, `samples.count` under-counts and the
        // summary's duration/time-in-zone fall short of real elapsed time.
        // The `.task` runs for the view's life and is cancelled on End ride.
        .task {
            let clock = ContinuousClock()
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1))
                recorder.ingest(controller.metrics)
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

    private func endRide() {
        let recording = recorder.finish()
        controller.stop()
        // Only persist rides that actually captured data.
        guard !recording.samples.isEmpty else { return }
        let ride = Ride.make(from: recording, zoning: rideZoning, hrZone: settings.hrZone)
        modelContext.insert(ride)
        try? modelContext.save()
        savedRide = ride
    }

    /// The zone model the ride is being scored against: the one latched at
    /// `.onAppear`, falling back to settings only on the first `body` evaluation
    /// (which runs before `.onAppear`) — at that point nothing has been ridden
    /// yet, so the two agree.
    private var rideZoning: RideHRZoning { zoning ?? settings.zoning }

    /// The target HR band the rider is chasing, under the latched zone model.
    private var targetHRBand: ClosedRange<Int> { rideZoning.bpmRange(for: settings.hrZone) }

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

    /// Cadence isn't a target the app holds, so there's no configured setting for
    /// it — this is a fixed endurance-comfortable window (~80–100 rpm) so the dial
    /// gives the same in-zone/push/ease cue as BPM and Watts.
    private var cadenceBand: ClosedRange<Int> { 80...100 }

}

/// Live "which zone am I in right now" readout for the ride screen: a segmented
/// Z1–Z5 bar with a handle marking where the current reading sits inside its zone.
/// Complements the `ZoneGauge` dials above it — those answer "am I inside my
/// *target* band?", this answers "which zone is this effort, on the model this
/// ride is being scored against?".
///
/// Deliberately shows no BPM number of its own: the BPM `ZoneGauge` already gives
/// the live figure with its in-zone/push/ease colouring, so a second copy here
/// was just noise competing with it. This is the *zone* readout; the gauge is the
/// *number* readout.
///
/// The zone it highlights is the one `RideHRZoning.zone(forHR:)` returns, i.e. the
/// exact classifier the ride's own time-in-zone scoring and the all-time per-zone
/// breakdown use. That's deliberate and worth preserving: the bar must never name a
/// different zone than the ride records for the same beat. Don't reintroduce a local
/// bucket-scan over `bpmRange`s here — the bands are inclusive on both ends and
/// overlap at their boundaries, so scanning them lands on the wrong zone (this is
/// the same double-count `secondsPerZone` documents avoiding).
private struct HRZoneBar: View {
    let bpm: Int?
    let zoning: RideHRZoning

    /// Where the live BPM sits inside its own zone's band, 0…1 — so the handle
    /// travels across the active segment as the effort climbs, rather than
    /// snapping to its start. Both engines clamp out-of-range readings into the
    /// end zones, so a value below Z1's floor or above Z5's ceiling pins to 0 or 1.
    private func fraction(of value: Int, in band: ClosedRange<Int>) -> Double {
        let span = Double(max(band.upperBound - band.lowerBound, 1))
        return min(max((Double(value) - Double(band.lowerBound)) / span, 0), 1)
    }

    var body: some View {
        // nil BPM (no strap yet, or a mid-ride dropout) is genuinely "no reading":
        // light no segment and hide the handle, rather than parking it in Z1 as a
        // confident 0 would. The BPM gauge below is what says "—" in that case.
        let active = bpm.map { zoning.zone(forHR: $0) }
        let handleFraction = bpm.map { fraction(of: $0, in: zoning.bpmRange(for: zoning.zone(forHR: $0))) }

        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let count = CGFloat(HRZone.allCases.count)
                let segmentWidth = geo.size.width / count

                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        ForEach(HRZone.allCases) { zone in
                            Capsule()
                                .fill(zone == active ? zone.color : zone.color.opacity(0.18))
                        }
                    }
                    .frame(height: 8)

                    if let active, let handleFraction {
                        // Zones are 1-indexed, so subtract 1 to get the segment offset.
                        let index = CGFloat(active.rawValue - 1)
                        let handleX = segmentWidth * (index + CGFloat(handleFraction))
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 18, height: 18)
                            .offset(x: handleX - 9)
                            .animation(.easeOut(duration: 0.3), value: handleX)
                    }
                }
            }
            .frame(height: 18)

            HStack(spacing: 0) {
                ForEach(HRZone.allCases) { zone in
                    Text(zone.shortName)
                        .font(.caption.weight(zone == active ? .bold : .regular))
                        .foregroundStyle(zone == active ? Color.primary : zone.color.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate")
        .accessibilityValue(bpm.map { "\($0) beats per minute, \(zoning.zone(forHR: $0).name)" }
            ?? "No reading")
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
/// you are), and a color-coded state chip beneath. Used identically for BPM,
/// watts, and cadence so the three read as one system. The ring sizes itself to
/// the column it's given so three fit across a phone; text scales to match.
private struct ZoneGauge: View {
    let value: Int?
    let band: ClosedRange<Int>
    let label: String
    let caption: String
    let icon: String
    /// Explicit ring diameter. On a phone the three columns are each narrower
    /// than the old 120-pt cap, so a `maxWidth` ceiling was never reached and
    /// every ring rendered the same size. Sizing the ring directly lets the
    /// center HR dial actually render a couple points larger than Watts/RPM.
    var ringSize: CGFloat = 104

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
                    .stroke(.quaternary, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(state.tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)

                VStack(spacing: 0) {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(state.tint)
                    Text(value.map { "\($0)" } ?? "—")
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(label)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            // Fixed square diameter so each ring renders at a known size (the
            // center HR dial passes a larger value). Capped small enough that
            // three fit across a narrow phone with a gap between the strokes.
            .frame(width: ringSize, height: ringSize)
            .padding(.horizontal, 4)

            // State chip: color + word + arrow. Redundant cues on purpose.
            Text(state.cue)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(state.tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(state.tint.opacity(0.15), in: Capsule())

            // Caption and band range on separate lines: at a phone's per-column
            // width the two together overflow and ellipsize ("Z2 Endurance · 13…"),
            // so stack them and use a smaller font that fits without clipping.
            VStack(spacing: 1) {
                Text(caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(band.lowerBound)–\(band.upperBound)")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                // Four of these have to fit on one line when a SRAM meter is
                // connected; scale the number down (never wrap) so the row stays
                // on a single line on a narrow phone.
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("\(title) · \(unit)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Nudge the ERG target up/down mid-ride without leaving the zone screen.
private struct TargetAdjuster: View {
    @Environment(TrainerController.self) private var controller
    @Environment(RideSettings.self) private var settings

    var body: some View {
        let current = controller.metrics.targetW ?? settings.target
        HStack(spacing: 16) {
            Button { controller.setTargetPower(current - 5) } label: {
                Image(systemName: "minus.circle.fill")
            }
            Text("Adjust target").font(.headline).foregroundStyle(.secondary)
            Button { controller.setTargetPower(current + 5) } label: {
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
