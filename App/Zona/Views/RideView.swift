import SwiftData
import SwiftUI
import ZonaKit

/// Live ride screen. BPM is the target the rider is chasing and watts is the
/// lever (ERG) they pull to get there; cadence is form. All three get an equal,
/// glanceable arc gauge side by side: each fills to show where the live value
/// sits within its band and shows a color + word + arrow cue (PUSH / HOLD /
/// EASE) so you know at a glance whether you're in target and which way to
/// correct — without relying on color alone. W/kg, speed and distance stay small
/// below, with the SRAM/Quarq readout on its own row under them; End ride
/// at the bottom. When the view appears we push the ERG target and start
/// recording; on End ride we save the ride to SwiftData and show its summary.
struct RideView: View {
    @Environment(TrainerController.self) private var controller
    @Environment(RideSettings.self) private var settings
    @Environment(IntervalLibrary.self) private var intervalLibrary
    @Environment(\.modelContext) private var modelContext

    @State private var recorder = RideRecorder()
    @State private var savedRide: Ride?
    /// Drives the "End ride?" confirmation so a stray tap can't discard a ride.
    @State private var confirmingEnd = false
    /// Drives the "Stop intervals?" confirmation. The stop button takes the
    /// "Add intervals" slot in the bottom row while a block runs — directly beside
    /// End ride — and stopping a block is not undoable (it banks the run and
    /// reverts ERG), so it gets the same guard as End ride rather than firing on
    /// the first tap.
    @State private var confirmingStopIntervals = false
    /// Drives the "Cancel countdown?" confirmation, in the same spot as the stop
    /// button and equally easy to hit by mistake. Unlike the other two this one
    /// races a clock: the countdown keeps ticking while the alert is up, and
    /// `cancelCountdown` is a no-op once it fires. `tickIntervals` therefore
    /// lowers the flag when the countdown ends, so the alert can't sit over a
    /// block that has already started.
    @State private var confirmingCancelCountdown = false
    /// Drives the sheet listing the saved interval library.
    @State private var showingIntervalPicker = false
    /// The interval-session playback lifecycle (`idle → countdown → running →
    /// idle`): the get-ready countdown, block start/end, ERG-write-only-on-boundary,
    /// and the revert-to-pre-block-target rule. Pure decision logic lives in
    /// `IntervalPlayback` (unit-tested in `ZonaKit`); this view only feeds it the
    /// elapsed second + FTP each tick and applies the `Action`s it returns to the
    /// trainer/recorder. `IntervalScheduler` (which it calls) is stateless, so
    /// elapsed-since-start recomputed from `recorder.elapsed()` is all it needs.
    @State private var playback = IntervalPlayback()
    /// The running block's current step, mirrored out of `playback` each tick so
    /// the HUD re-renders (SwiftUI observes this `@State`, not the struct's pure
    /// read). nil whenever no block is running.
    @State private var currentIntervalState: IntervalTargetState?

    /// How long the rider gets to settle after choosing a session before its
    /// first block starts driving ERG.
    private let intervalCountdownSeconds = 15
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
            // Total ride time on the left; time spent in the target HR zone on the
            // right, so the rider can see at a glance how much of the ride has
            // actually landed where they were aiming.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 28) {
                    labelledTime("Total", elapsedText(asOf: context.date))
                    labelledTime("In zone", inZoneText, tint: .green)
                }
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
                    ringSize: 120,
                    // Green/push/ease from the zone classifier (not the rounded
                    // band), so this dial and the Z1–Z5 bar below never name a
                    // different zone for the same beat.
                    stateOverride: ZoneState(bpm: controller.metrics.heartRateBpm,
                                             target: settings.hrZone,
                                             zoning: rideZoning)
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
            HRZoneBar(bpm: controller.metrics.heartRateBpm,
                      target: settings.hrZone,
                      zoning: rideZoning)

            // Watts/kg, Speed and Distance — the trainer-derived secondary
            // readouts — share one line.
            HStack(spacing: 16) {
                Metric(title: "W/kg",
                       value: wattsPerKgText,
                       unit: "",
                       spokenLabel: "Watts per kilogram")
                Metric(title: "Speed",
                       value: controller.metrics.speedKph.map { String(format: "%.1f", $0) } ?? "—",
                       unit: "km/h")
                Metric(title: "Distance",
                       value: String(format: "%.2f", recorder.distanceMeters / 1000),
                       unit: "km")
            }
            .frame(maxWidth: .infinity)

            // The SRAM/Quarq readout (power + cadence) gets its own row below —
            // it's a separate sensor from the trainer, and keeping it off the
            // line above means neither row has to squeeze. The meter's watts are
            // recorded as leg power on their own channel, and a finished ride
            // can export them (see `TCXPowerSource`); its cadence stays
            // display-only. Neither feeds ERG or the zone math — the trainer
            // drives those (see `RideMetrics.powerMeterW`).
            //
            // The row is keyed on the meter being *connected*, not on it having
            // a current reading. Those differ constantly: a quiet crank sends
            // nothing rather than a 0 W frame, so the values expire after a few
            // seconds of coasting and go nil. Keying on the reading would make
            // the whole row vanish and shift the layout every time the rider
            // stopped pedalling. Expired values render "—" — never 0, which
            // would claim the rider held watts they didn't (see
            // `RideMetrics.powerMeterW`).
            if controller.sensorState(.powerMeter).isConnected {
                HStack(spacing: 16) {
                    Metric(title: "SRAM",
                           value: powerMeterWattsPerKgText,
                           unit: "W/kg",
                           spokenLabel: "Leg watts per kilogram")
                    Metric(title: "SRAM",
                           value: controller.metrics.powerMeterW.map { "\($0)" } ?? "—",
                           unit: "W",
                           spokenLabel: "Leg power")
                    Metric(title: "SRAM",
                           value: controller.metrics.powerMeterCadenceRpm.map { "\($0)" } ?? "—",
                           unit: "RPM",
                           spokenLabel: "Leg cadence")
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            // The scheduler owns the target while a block is running, so the
            // manual adjuster (which would fight it) is swapped for a compact
            // HUD showing progress and the block's trim. Stopping early is in the
            // bottom button row, not here. Before that, a chosen session sits in a
            // "get ready" countdown with its own HUD (whose Cancel *is* in the HUD,
            // since the bottom row still offers Add intervals during a countdown).
            if let remaining = playback.countdownRemaining, let session = playback.countingSession {
                IntervalCountdownHUD(secondsRemaining: remaining,
                                     sessionName: session.name,
                                     onCancel: { confirmingCancelCountdown = true })
            } else if let state = currentIntervalState, let session = playback.runningSession {
                IntervalHUD(state: state,
                            sessionName: session.name,
                            offsetW: playback.offsetW,
                            onTrim: trimInterval)
            } else {
                TargetAdjuster()
            }

            Spacer()

            // The interval button (blue) and End ride (red) share one line, equal
            // width. Intervals are only offered on a Zone 2 ride — Zone 1 is
            // recovery-steady and has no interval mode — so on a Zone 1 ride the
            // slot is empty and End ride spans the row on its own.
            //
            // While a block runs the slot becomes an orange "Stop intervals"
            // rather than a greyed-out "Add intervals": the disabled state gave
            // the biggest control on screen to a button that did nothing, and the
            // only thing the rider wants from that slot mid-block is the way out.
            // Orange separates it from both neighbours — it is not the ride-ending
            // red, and not the idle blue whose place it takes. It raises the same
            // `confirmingStopIntervals` alert the HUD's stop button does, so
            // `endInterval` stays the single path into `playback.stop`.
            //
            // A *countdown* keeps showing the disabled Add intervals: its own
            // Cancel lives in the HUD above, and a second control that reads
            // "Stop intervals" for a session that hasn't started yet would ask
            // the rider to tell two similar-sounding outs apart mid-effort.
            HStack(spacing: 12) {
                if settings.zone == .z2Endurance {
                    if playback.isRunning {
                        Button {
                            confirmingStopIntervals = true
                        } label: {
                            Label("Stop intervals", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    } else {
                        Button {
                            showingIntervalPicker = true
                        } label: {
                            Label("Add intervals", systemImage: "timer").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(intervalLibrary.sessions.isEmpty || playback.isCounting)
                    }
                }

                Button(role: .destructive) { confirmingEnd = true } label: {
                    Text("End ride").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
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
        // Same guard as End ride, and for the same reason: the tap that stops a
        // block is easy to make by accident and impossible to take back. Keeping
        // it dismissible ("Keep going" is the cancel role) means a stray tap
        // costs a dismissal, not the rest of the session.
        .alert("Stop intervals?", isPresented: $confirmingStopIntervals) {
            Button("Stop intervals", role: .destructive, action: endInterval)
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("This ends the interval session and returns to your steady target. The ride keeps recording.")
        }
        // The countdown's Cancel gets the same guard, in the same spot on screen.
        // Nothing is destroyed by cancelling — no run to record, the steady target
        // was never left — but the cost of a stray tap is asymmetric: it silently
        // drops a session the rider queued and was waiting on, and the countdown
        // gives no second chance to notice.
        .alert("Cancel countdown?", isPresented: $confirmingCancelCountdown) {
            Button("Cancel countdown", role: .destructive, action: cancelCountdown)
            Button("Keep counting", role: .cancel) {}
        } message: {
            Text("The interval session won't start. Your steady target is unchanged.")
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
                // Expire a quiet power meter *before* banking the second, so a
                // coast records nil rather than the meter's last wattage. This
                // tick is the only clock that keeps running when the whole BLE
                // bus goes silent, which is exactly when the hub's own
                // sweep-on-reading can't fire (see `sweepStalePowerMeter`).
                controller.sweepStalePowerMeter()
                recorder.ingest(controller.metrics)
                tickIntervals()
            }
        }
        .sheet(isPresented: $showingIntervalPicker) {
            IntervalPickerSheet(sessions: intervalLibrary.sessions, onSelect: beginCountdown)
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

    /// Arm a chosen session with a short "get ready" countdown rather than
    /// starting it outright, so the first work block doesn't snap the ERG up the
    /// instant the picker dismisses. `IntervalPlayback` counts it down on the 1 Hz
    /// tick and starts the block when it reaches 0. The ERG target in force *now*
    /// — including any mid-ride `TargetAdjuster` trim — is captured here, at arm
    /// time, so ending the block reverts there rather than to the computed steady
    /// value (the pre-block-revert rule); by the time the countdown fires this
    /// context is gone.
    private func beginCountdown(_ session: IntervalSession) {
        playback.beginCountdown(session,
                                seconds: intervalCountdownSeconds,
                                preTargetW: controller.metrics.targetW ?? settings.target)
    }

    /// Abandon a countdown before it fires, leaving the steady target untouched.
    private func cancelCountdown() {
        playback.cancelCountdown()
    }

    /// Advance interval playback by one 1 Hz tick and apply whatever it decides:
    /// decrement/fire the countdown, push a new ERG setpoint at a step boundary,
    /// or record-then-revert when a block ends. `IntervalPlayback` owns all that
    /// logic; this only feeds it the elapsed second + FTP and applies the returned
    /// `Action`s. The HUD's step state is a pure read mirrored out afterwards.
    private func tickIntervals() {
        apply(playback.tick(elapsed: recorder.elapsed(), ftp: settings.ftp))
        currentIntervalState = playback.currentState(elapsed: recorder.elapsed(), ftp: settings.ftp)
        // Both confirmations can be outlived by the state they're asking about:
        // a session can finish on its own, and a countdown always fires on its
        // own if left alone. Confirming either would be harmless (`stop` and
        // `cancelCountdown` both guard on their phase and return no actions
        // otherwise), but the rider would be answering a stale question — and in
        // the countdown's case a misleading one, since the block it offered to
        // prevent is by then already driving ERG.
        if !playback.isRunning { confirmingStopIntervals = false }
        if !playback.isCounting { confirmingCancelCountdown = false }
    }

    /// Trim the running block's ERG target by `deltaW` from the HUD. The offset
    /// is applied to every remaining step by `IntervalPlayback`, not written to
    /// the trainer directly — a direct write would be stomped at the next step
    /// boundary, which is exactly why the manual `TargetAdjuster` is hidden while
    /// a block runs. The HUD's step state is re-mirrored so the trimmed target
    /// shows immediately rather than a second later on the next tick.
    private func trimInterval(_ deltaW: Int) {
        apply(playback.trim(byW: deltaW, elapsed: recorder.elapsed(), ftp: settings.ftp))
        currentIntervalState = playback.currentState(elapsed: recorder.elapsed(), ftp: settings.ftp)
    }

    /// Stop the running block early from the HUD. `IntervalPlayback.stop` returns
    /// the record-then-revert actions (a no-op outside a running block).
    private func endInterval() {
        apply(playback.stop(atElapsed: recorder.elapsed()))
        currentIntervalState = nil
    }

    /// Apply the intents `IntervalPlayback` returns, in order — the only place
    /// this view touches the trainer/recorder on the intervals' behalf. Order is
    /// load-bearing: `recordRun` is always emitted before `revert` so the finished
    /// run is banked before the target is restored (and before `finish()` locks
    /// the recording).
    private func apply(_ actions: [IntervalPlayback.Action]) {
        for action in actions {
            switch action {
            case let .setWatts(watts):
                controller.setTargetPower(watts)
            case let .revert(toWatts):
                controller.setTargetPower(toWatts)
            case let .recordRun(session, startedAtSecond, actualSeconds):
                recorder.recordInterval(session,
                                        startedAtSecond: startedAtSecond,
                                        actualSeconds: actualSeconds)
            }
        }
    }

    private func endRide() {
        // If a block is still running, record it (as a stopped-early run) before
        // finishing — `finish()` locks the recording, so an in-progress interval
        // would otherwise be dropped from the summary.
        if playback.isRunning { endInterval() }
        let recording = recorder.finish()
        controller.stop()
        // Only persist rides that actually captured data.
        guard !recording.samples.isEmpty else { return }
        let ride = Ride.make(from: recording, zoning: rideZoning, hrZone: settings.hrZone,
                            weightKg: settings.effectiveWeightKg)
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

    /// Seconds so far spent inside the target HR zone, as mm:ss. Each recorded
    /// second with an HR reading inside the target band counts as one second,
    /// using the same classifier the finished ride is scored with — so this
    /// running figure agrees with the summary's time-in-zone. Reading
    /// `recorder.samples` here ties the recompute to new samples landing.
    private var inZoneText: String {
        let bpms = recorder.samples.compactMap(\.heartRateBpm)
        let s = rideZoning.secondsInZone(settings.hrZone, bpms: bpms)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// One labelled mm:ss readout: the time over a small uppercase caption, so
    /// Total and In zone read as a matched pair.
    private func labelledTime(_ label: String, _ time: String, tint: Color = .secondary) -> some View {
        VStack(spacing: 2) {
            Text(time)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Live watts-per-kilogram, using WHOOP's body weight when available (see
    /// `RideSettings.effectiveWeightKg`), else the manually entered weight. "—"
    /// with no trainer reading, same as the other live tiles.
    private var wattsPerKgText: String {
        PowerPerWeight.wattsPerKg(watts: controller.metrics.powerW, weightKg: settings.effectiveWeightKg)
            .map { String(format: "%.1f", $0) } ?? "—"
    }

    /// Watts-per-kilogram from the SRAM/Quarq meter's leg power, same "—" on
    /// no reading as the other SRAM tiles (see `RideMetrics.powerMeterW`).
    private var powerMeterWattsPerKgText: String {
        PowerPerWeight.wattsPerKg(watts: controller.metrics.powerMeterW, weightKg: settings.effectiveWeightKg)
            .map { String(format: "%.1f", $0) } ?? "—"
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
    /// The zone the rider is aiming at. Its segment is outlined so the target is
    /// visible even before a reading arrives, and the handle is tinted by whether
    /// the live effort is below / on / above it.
    let target: HRZone
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
        // Below / on / above target, from the SAME classifier the BPM dial's
        // PUSH/HOLD/EASE chip uses — so the bar's handle and that chip can never
        // disagree about whether the rider is on target. `.noData` when there's no
        // reading, which leaves the handle hidden anyway.
        let state = ZoneState(bpm: bpm, target: target, zoning: zoning)

        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let count = CGFloat(HRZone.allCases.count)
                let segmentWidth = geo.size.width / count

                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        ForEach(HRZone.allCases) { zone in
                            Capsule()
                                .fill(zone == active ? zone.color : zone.color.opacity(0.18))
                                // Outline the target segment so "where I'm meant to
                                // be" reads at a glance, distinct from the filled
                                // "where I am" segment. When the two coincide the
                                // rider is on target — the filled segment sits
                                // inside its own outline.
                                .overlay(
                                    Capsule()
                                        .strokeBorder(zone == target ? Color.primary.opacity(0.55)
                                                                     : .clear,
                                                      lineWidth: 2)
                                )
                        }
                    }
                    .frame(height: 8)

                    if let active, let handleFraction {
                        // Zones are 1-indexed, so subtract 1 to get the segment offset.
                        let index = CGFloat(active.rawValue - 1)
                        let handleX = segmentWidth * (index + CGFloat(handleFraction))
                        Circle()
                            .fill(state.tint)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 2))
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
                        .font(.caption.weight(zone == active || zone == target ? .bold : .regular))
                        .foregroundStyle(zone == active ? Color.primary : zone.color.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate")
        .accessibilityValue(accessibilityValue)
    }

    /// Spoken as "148 beats per minute, Z2 Endurance, on target" — the on/below/
    /// above phrase mirrors the dial's PUSH/HOLD/EASE cue so VoiceOver users get
    /// the same three-way state sighted users read from the handle's colour.
    private var accessibilityValue: String {
        guard let bpm else { return "No reading" }
        let zone = zoning.zone(forHR: bpm)
        let relation: String
        switch ZoneState(bpm: bpm, target: target, zoning: zoning) {
        case .below:  relation = "below target \(target.shortName)"
        case .inZone: relation = "on target"
        case .above:  relation = "above target \(target.shortName)"
        case .noData: relation = ""
        }
        return "\(bpm) beats per minute, \(zone.name), \(relation)"
    }
}

/// How an on-target state is painted. The state itself — and its `cue` string —
/// is pure and unit-tested in `ZonaKit`; only the colour lives here.
///
/// Deliberately app-target, the same split as `HRZone.color`: routing every
/// on-target decision through one `ZoneState` is what keeps the dial, the zone
/// bar and the summary agreeing beat-for-beat, and that decision is worth
/// testing without SwiftUI in the way. How it's tinted isn't.
extension ZoneState {
    var tint: Color {
        switch self {
        case .noData: return .gray
        case .below:  return .blue    // too easy
        case .inZone: return .green
        case .above:  return .orange  // too hard
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
    /// Optional pre-computed state. The HR dial passes one derived from the zone
    /// *classifier* so its green/push/ease cue agrees to the beat with the zone
    /// bar; watts and cadence leave this nil and fall back to band membership.
    var stateOverride: ZoneState?

    private var state: ZoneState { stateOverride ?? ZoneState(value: value, band: band) }

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
    /// What VoiceOver announces instead of `title`, when the visual caption is
    /// too terse to stand alone. The row deliberately repeats short titles —
    /// three tiles read "SRAM" and two read "W/kg" — which works sighted,
    /// where position and the unit disambiguate at a glance, but leaves
    /// VoiceOver saying "SRAM" three times with nothing to tell them apart.
    /// Defaults to `title` for tiles whose caption already reads as a phrase.
    var spokenLabel: String?

    /// The value text's designed point size. Pinned as the tile's fixed height
    /// too, so the number only ever scales down to fit its row's *width* — see
    /// below.
    private let valueSize: CGFloat = 34

    var body: some View {
        VStack {
            Text(value)
                .font(.system(size: valueSize, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                // Up to three of these share one line — the W/kg/Speed/Distance
                // row, and the SRAM row (W/kg, W, RPM) when a meter is
                // connected; scale the number down (never wrap) so the row stays
                // on a single line on a narrow phone.
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                // Width is the only pressure that may shrink the number. Without
                // a fixed height these tiles are the most compressible thing in
                // the ride column, so they were the first to give when something
                // taller appeared *below* them: starting an interval session
                // swaps the one-line `TargetAdjuster` for the much taller
                // `IntervalHUD`, and all six readings visibly shrank for the rest
                // of the session — exactly when the rider is working hardest and
                // least able to read them. The height reservation makes the
                // surrounding `Spacer`s absorb that instead.
                .frame(height: valueSize)
            Text(unit.isEmpty ? title : "\(title) · \(unit)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        // Merge the number and its caption into one element: read separately
        // they arrive as two stops ("3.4", then "SRAM · W/kg"), so a rider
        // swiping the row hears twice as many stops as there are readings.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel ?? title)
        .accessibilityValue(accessibilityValue)
    }

    /// "3.4 watts per kilogram", or "No reading" for the em-dash the tiles show
    /// when a value is missing — a bare "—" is announced as punctuation (or
    /// skipped), which tells the rider nothing. Units are spelled out because
    /// VoiceOver reads "W" as the letter and "RPM" letter-by-letter.
    private var accessibilityValue: String {
        guard value != "—" else { return "No reading" }
        return unit.isEmpty ? value : "\(value) \(spokenUnit)"
    }

    private var spokenUnit: String {
        switch unit {
        case "W":     return "watts"
        case "RPM":   return "revolutions per minute"
        case "W/kg":  return "watts per kilogram"
        case "km/h":  return "kilometres per hour"
        case "km":    return "kilometres"
        default:      return unit
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
            Text("Adjust target").font(.headline).foregroundStyle(.secondary)
            Button { controller.setTargetPower(current + 5) } label: {
                Image(systemName: "plus.circle.fill")
            }
        }
        .font(.title2)
        .buttonStyle(.plain)
    }
}

/// Compact HUD shown in place of `TargetAdjuster` while an interval block owns
/// the ERG target: which step, its zone, and time left in it, plus the ±5 W trim.
/// Stopping the block early lives in the ride screen's bottom button row, where
/// it takes over the "Add intervals" slot — the HUD carried a duplicate of it
/// until then.
///
/// For the common uniform session it counts **reps** ("Rep 3 of 4 · REST"),
/// because mid-set the question is "how many hard efforts left?" and a raw step
/// number answers that only after arithmetic the rider shouldn't be doing at
/// threshold. A genuinely free-form session (warmup, ramp, pyramid) has no
/// work/rest alternation to label, so it falls back to counting steps and naming
/// the step's zone. `IntervalTargetState.repetition` makes that distinction in
/// ZonaKit, where it's unit-tested — the view just picks a string.
private struct IntervalHUD: View {
    let state: IntervalTargetState
    let sessionName: String
    /// The rider's current trim, for the "+10 W" chip. 0 means untrimmed and the
    /// chip is hidden — an always-present "0 W" would read as a reading rather
    /// than as an adjustment they made.
    let offsetW: Int
    let onTrim: (Int) -> Void

    /// Same ±5 W step the manual `TargetAdjuster` uses, so trimming feels the
    /// same whether or not a block is running.
    private let trimStepW = 5

    private var offsetText: String {
        offsetW > 0 ? "+\(offsetW) W" : "\(offsetW) W"
    }

    /// One short line, read at a glance mid-effort.
    private var line: String {
        let time = mmss(state.secondsRemainingInStep)
        if let rep = state.repetition {
            return "Rep \(rep.index + 1) of \(rep.total) · \(rep.isWork ? "WORK" : "REST") · \(time)"
        }
        return "Step \(state.stepIndex + 1) of \(state.totalSteps) · \(state.zone.shortName) · \(time)"
    }

    /// Warm while working, cool while recovering. For a uniform set that's the
    /// work/rest half; otherwise it falls back to the zone's intensity — the
    /// same orange/blue split the summary's step rows use, without inventing a
    /// PowerZone→Color ramp (PowerZone has 7 cases to HRZone's 5, so they don't
    /// map cleanly onto `HRZone.color`).
    private var tint: Color {
        if let rep = state.repetition { return rep.isWork ? .orange : .blue }
        return state.zone.rawValue >= PowerZone.z3Tempo.rawValue ? .orange : .blue
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(sessionName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(line)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())

            // Mid-block trim. The scheduler still owns the setpoint — this feeds
            // it an offset that carries to every remaining step, so the next step
            // boundary doesn't stomp the correction. The target shown is the
            // trimmed one, i.e. what ERG is actually holding.
            HStack(spacing: 16) {
                Button { onTrim(-trimStepW) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .accessibilityLabel("Decrease interval target by \(trimStepW) watts")

                VStack(spacing: 2) {
                    Text("\(state.targetWatts) W")
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                    if offsetW != 0 {
                        Text(offsetText)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 74)
                // One VoiceOver stop for the readout, with the trim spelled out
                // rather than left as a bare signed number beside it.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Interval target")
                .accessibilityValue(offsetW == 0
                                    ? "\(state.targetWatts) watts"
                                    : "\(state.targetWatts) watts, trimmed \(offsetText)")

                Button { onTrim(trimStepW) } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Increase interval target by \(trimStepW) watts")
            }
            .font(.title2)
            .buttonStyle(.plain)
        }
    }

    private func mmss(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// "Get ready" HUD shown after a session is chosen but before its first block
/// starts driving ERG: a short countdown so the rider can settle, with a way to
/// back out before it fires.
private struct IntervalCountdownHUD: View {
    let secondsRemaining: Int
    let sessionName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(sessionName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Starting in \(secondsRemaining)")
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.orange)
                .contentTransition(.numericText())
            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Sheet listing the saved interval library. Tapping a session starts it
/// immediately — there's no separate "queued, then start" step.
private struct IntervalPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sessions: [IntervalSession]
    let onSelect: (IntervalSession) -> Void

    var body: some View {
        NavigationStack {
            List(sessions) { session in
                Button {
                    onSelect(session)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name).font(.headline)
                        Text(session.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Start intervals")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    RideView()
        .environment(TrainerController())
        .environment(RideSettings())
        .environment(IntervalLibrary())
}
