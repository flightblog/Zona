import Charts
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
                    band: settings.targetHRBand,
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

            HStack(spacing: 32) {
                Metric(title: "Speed",
                       value: controller.metrics.speedKph.map { String(format: "%.1f", $0) } ?? "—",
                       unit: "km/h")
                Metric(title: "Distance",
                       value: String(format: "%.2f", recorder.distanceMeters / 1000),
                       unit: "km")
            }

            // Secondary SRAM/Quarq readout on its own row below Speed/Distance —
            // power, cadence, and L/R balance. Only appears when the meter is
            // connected and reporting. Informational: none of it is recorded,
            // exported, or used by ERG (see `RideMetrics.powerMeterW`).
            if let meterW = controller.metrics.powerMeterW {
                HStack(spacing: 32) {
                    Metric(title: "SRAM", value: "\(meterW)", unit: "W")
                    Metric(title: "Cadence",
                           value: controller.metrics.powerMeterCadenceRpm.map { "\($0)" } ?? "—",
                           unit: "rpm")
                    Metric(title: "Balance",
                           value: balanceText(controller.metrics.powerMeterBalancePercent),
                           unit: "L/R")
                }
            }

            // Live time-series of the two numbers that matter during the ride:
            // trainer watts (left axis, the lever) and BPM (right axis, the
            // target). Reads the recorder's ordered samples, so it grows a point
            // per second as the ride runs. Only shows once there's something to
            // plot — before the first sample it would be an empty box. Bound once
            // (samples sorts on each read) rather than reading it twice.
            let liveSamples = recorder.samples
            if liveSamples.contains(where: { $0.powerW != nil || $0.heartRateBpm != nil }) {
                RidePowerHRChart(samples: liveSamples)
                    .frame(height: 160)
            }

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
            // Enter ERG at the configured steady target and start recording.
            controller.setTargetPower(settings.target)
            recorder.start(ftp: settings.ftp, zone: settings.zone)
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

    /// Cadence isn't a target the app holds, so there's no configured setting for
    /// it — this is a fixed endurance-comfortable window (~80–100 rpm) so the dial
    /// gives the same in-zone/push/ease cue as BPM and Watts.
    private var cadenceBand: ClosedRange<Int> { 80...100 }

    /// Render the power meter's pedal balance as "L–R" whole-percent shares. The
    /// meter reports one leg's share; the other is its complement. "—" when the
    /// meter doesn't send balance.
    private func balanceText(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        let left = Int(percent.rounded())
        return "\(left)–\(100 - left)"
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
            Text("\(title) · \(unit)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Live dual-axis time-series for the ride screen: trainer watts on the LEFT
/// axis, heart rate (BPM) on the RIGHT axis, both against elapsed seconds.
///
/// Swift Charts plots every mark against one shared Y-domain, so a true second
/// axis is faked the standard way: watts are plotted in their natural units and
/// own the (leading) left axis; BPM is *scaled into the watts domain* before
/// plotting, then the (trailing) right axis is relabelled back to real BPM. The
/// result reads as two independent scales — a 130 W line and a 130 bpm line
/// don't have to overlap — while Charts still sees a single domain underneath.
private struct RidePowerHRChart: View {
    let samples: [RideSample]

    /// At most this many points reach Charts. A `LineMark` per second makes a
    /// long ride thousands of marks and the screen lags; a chart this wide can't
    /// resolve more than a few hundred points anyway. See `downsampled(to:)`.
    private let maxPoints = 200

    /// Watts axis fixed range. Anchored at 0 with a little headroom over the
    /// ride's peak so the left axis doesn't rescale every second and make the
    /// line jump; 300 W is a sane floor for a Z1/Z2 endurance ride.
    private func wattRange(_ points: [ChartPoint]) -> ClosedRange<Double> {
        let peak = points.compactMap(\.watts).max() ?? 0
        return 0...max(300, peak * 1.15)
    }

    /// BPM axis fixed range. A resting-to-hard endurance window; padded past the
    /// ride's own max so the HR line isn't clipped at the top.
    private func bpmRange(_ points: [ChartPoint]) -> ClosedRange<Double> {
        let peak = points.compactMap(\.bpm).max() ?? 0
        return 40...max(180, peak * 1.1)
    }

    var body: some View {
        // Compute the plotted points and both axis ranges ONCE per render. These
        // used to be computed properties, but `wattsForBPM` reads both ranges and
        // is called once per point (plus per axis label), and each range read
        // re-ran the whole sort+downsample — so a long ride reprocessed all its
        // samples hundreds of times per layout pass and locked up the UI. Binding
        // them here means the O(n log n) reduction runs exactly once.
        let points = samples
            .map { ChartPoint(seconds: $0.secondsFromStart,
                              watts: $0.powerW.map(Double.init),
                              bpm: $0.heartRateBpm.map(Double.init)) }
            .downsampled(to: maxPoints)
        let wattRange = wattRange(points)
        let bpmRange = bpmRange(points)

        return Chart {
            ForEach(points, id: \.seconds) { point in
                if let power = point.watts {
                    LineMark(
                        x: .value("Time", point.seconds),
                        y: .value("Watts", power),
                        series: .value("Series", "Watts")
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.monotone)
                }
                if let hr = point.bpm {
                    LineMark(
                        x: .value("Time", point.seconds),
                        y: .value("BPM", scaleBPMToWatts(hr, bpmRange: bpmRange, wattRange: wattRange)),
                        series: .value("Series", "BPM")
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(["Watts": Color.blue, "BPM": Color.red])
        .chartYScale(domain: wattRange)
        // Both axes share the watts domain (so the tick positions line up), but
        // one .chartYAxis block must declare them together — a second call would
        // replace the first, not add to it.
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
/// computed once per render, never re-derived per call. Shared by the live ride
/// chart here and the summary's `PowerChart`.
func scaleBPMToWatts(_ bpm: Double,
                     bpmRange: ClosedRange<Double>,
                     wattRange: ClosedRange<Double>) -> Double {
    let frac = (bpm - bpmRange.lowerBound) / (bpmRange.upperBound - bpmRange.lowerBound)
    return wattRange.lowerBound + frac * (wattRange.upperBound - wattRange.lowerBound)
}

/// Inverse of `scaleBPMToWatts`: turn a watts-domain axis tick back into the BPM
/// it represents, for relabelling the right axis.
func unscaleWattsToBPM(_ watts: Double,
                       bpmRange: ClosedRange<Double>,
                       wattRange: ClosedRange<Double>) -> Int {
    let frac = (watts - wattRange.lowerBound) / (wattRange.upperBound - wattRange.lowerBound)
    return Int((bpmRange.lowerBound + frac * (bpmRange.upperBound - bpmRange.lowerBound)).rounded())
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
