import SwiftData
import SwiftUI
import ZonaKit

/// Live ride: big power dial that turns green when you're holding the target
/// zone, plus cadence/speed, and a stop button. When the view appears we push
/// the computed ERG target to the trainer and start recording; on End ride we
/// save the ride to SwiftData and show its summary.
struct RideView: View {
    @Environment(TrainerController.self) private var controller
    @Environment(RideSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var recorder = RideRecorder()
    @State private var savedRide: Ride?

    var body: some View {
        VStack(spacing: 24) {
            Text(elapsedText)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)

            PowerDial(
                power: controller.metrics.powerW,
                target: controller.metrics.targetW ?? settings.target,
                inZone: isInZone
            )

            // HR is the zone target now — give it a prominent, color-coded readout.
            HeartRateReadout(
                bpm: controller.metrics.heartRateBpm,
                targetBand: settings.targetHRBand,
                targetZoneName: settings.hrZone.name
            )

            HStack(spacing: 32) {
                Metric(title: "Cadence",
                       value: controller.metrics.cadenceRpm.map { "\($0)" } ?? "—",
                       unit: "rpm")
                Metric(title: "Speed",
                       value: controller.metrics.speedKph.map { String(format: "%.1f", $0) } ?? "—",
                       unit: "km/h")
            }

            TargetAdjuster()

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

    private var elapsedText: String {
        let s = recorder.elapsedSeconds
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var isInZone: Bool {
        guard let power = controller.metrics.powerW else { return false }
        let range = settings.engine.wattRange(for: settings.zone)
        return range.contains(power)
    }
}

/// Circular target dial. Ring fills toward the target; color signals in/out of
/// zone so you can hold steady without reading numbers.
private struct PowerDial: View {
    let power: Int?
    let target: Int
    let inZone: Bool

    private var fraction: Double {
        guard let power, target > 0 else { return 0 }
        return min(Double(power) / Double(target * 2), 1) // target sits at 50%
    }

    private var tint: Color {
        power == nil ? .gray : (inZone ? .green : .orange)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 18)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: fraction)

            VStack(spacing: 2) {
                Text(power.map { "\($0)" } ?? "—")
                    .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("watts").font(.subheadline).foregroundStyle(.secondary)
                Text("target \(target) W")
                    .font(.footnote)
                    .foregroundStyle(tint)
                    .padding(.top, 4)
            }
        }
        .frame(width: 240, height: 240)
    }
}

/// Live heart-rate readout, color-coded by whether HR is in the target band.
/// Since zones are HR-based, this is the rider's primary "am I in zone?" cue —
/// power still holds via ERG, but HR is what defines the zone.
private struct HeartRateReadout: View {
    let bpm: Int?
    let targetBand: ClosedRange<Int>
    let targetZoneName: String

    private var inZone: Bool {
        guard let bpm else { return false }
        return targetBand.contains(bpm)
    }

    private var tint: Color {
        guard let bpm else { return .gray }
        if inZone { return .green }
        // Below band = too easy (blue), above = too hard (orange).
        return bpm < targetBand.lowerBound ? .blue : .orange
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill").foregroundStyle(tint)
                Text(bpm.map { "\($0)" } ?? "—")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("bpm").font(.headline).foregroundStyle(.secondary)
            }
            Text("\(targetZoneName) · \(targetBand.lowerBound)–\(targetBand.upperBound) bpm")
                .font(.footnote)
                .foregroundStyle(tint)
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
                .font(.title2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text("\(title) · \(unit)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            Text("Adjust target").font(.callout).foregroundStyle(.secondary)
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
