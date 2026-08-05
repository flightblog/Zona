import Foundation
import Observation

/// App-facing controller for a ride session. Presents a single, view-friendly
/// surface (`connection`, `metrics`, `setTargetPower`, `stop`) backed by the
/// multi-sensor `SensorHub`.
///
/// The trainer's FTMS behavior is unchanged from the original single-peripheral
/// implementation — it now just lives inside `SensorHub`. This facade adds
/// heart-rate awareness: when `requiresHeartRate` is set, the session is only
/// `.ready` once both the trainer and an HR strap are connected.
@MainActor
@Observable
public final class TrainerController {
    /// If true, a ride can't start until an HR sensor is connected.
    public var requiresHeartRate: Bool = false

    /// Live merged metrics — a REAL observed stored property, republished from
    /// the hub via `onMetricsChange`. It must be stored (not a computed
    /// pass-through to `hub.metrics`): SwiftUI observes what the view reads, and
    /// the view reads `controller`, not `hub`. A computed pass-through registered
    /// no dependency, so live values (power/HR/cadence/speed) never refreshed —
    /// they updated only when an unrelated render happened to re-read them.
    public private(set) var metrics = RideMetrics()

    /// Devices found by an active browse scan (see `startBrowsing`), mirrored
    /// from the hub for the same reason `metrics` is: the view observes the
    /// controller, not the hub. Empty unless browsing.
    public private(set) var discovered: [DiscoveredSensor] = []

    // The hub owns BLE + control; it's observed internally but the view goes
    // through this controller, so we mirror its state into observed properties.
    @ObservationIgnored private let hub: SensorHub

    // Observed snapshots mirrored from the hub on every state change, so views
    // reading through this controller re-render. (Views observe `controller`,
    // not `hub`; a computed pass-through to `hub` registers no dependency, which
    // is why live values were frozen until an unrelated render occurred.)
    private var states: [SensorKind: SensorConnectionState] = [:]
    private var mirroredTrainerReady = false
    private var mirroredDesiredKinds: Set<SensorKind> = []

    public init(memory: SensorMemory = EphemeralSensorMemory()) {
        self.hub = SensorHub(memory: memory)
        // Republish hub changes as our own observed state so SwiftUI re-renders.
        self.hub.onStateChange = { [weak self] in self?.syncState() }
        self.hub.onMetricsChange = { [weak self] m in self?.metrics = m }
        self.hub.onDiscoveryChange = { [weak self] d in self?.discovered = d }
    }

    /// Copy hub state into observed storage and re-evaluate the ride latch.
    private func syncState() {
        states = hub.states
        mirroredTrainerReady = hub.trainerReady
        mirroredDesiredKinds = hub.desiredKinds
        updateLatch()
    }

    // MARK: - Published, view-facing state (derived from the hub)

    /// Per-sensor connection state, for setup rows. Reads observed `states`.
    public func sensorState(_ kind: SensorKind) -> SensorConnectionState {
        states[kind] ?? .disconnected
    }

    public var log: [String] { hub.log }

    /// Append a line to the ride event log.
    public func note(_ line: String) { hub.note(line) }

    /// Latches true once a ride's start conditions are first met, and stays true
    /// until `stop()`. Without this, a mid-ride HR strap flap (they disconnect
    /// on idle) would drop `connection` out of `.ready` and eject the rider back
    /// to the setup screen. Starting requires HR; *staying* in the ride does not.
    /// Set only from `updateLatch()` (a real state transition), never from the
    /// `connection` getter — mutating during a read breaks observation.
    public private(set) var sessionLatched = false

    /// Re-evaluate whether the ride has started. Call after any sensor state
    /// change. Idempotent; only ever flips the latch on (off happens in `stop`).
    public func updateLatch() {
        guard !sessionLatched, mirroredTrainerReady else { return }
        if requiresHeartRate && !(states[.heartRate]?.isConnected ?? false) { return }
        sessionLatched = true
    }

    /// Collapsed lifecycle state the top-level UI switches on. Maps the mirrored
    /// per-sensor states into the existing `ConnectionState` the views use.
    /// Reads only observed storage so SwiftUI tracks it; no mutation.
    public var connection: ConnectionState {
        let trainer = states[.trainer] ?? .disconnected

        // Nothing started yet.
        if mirroredDesiredKinds.isEmpty { return .idle }

        // Once a ride has started, stay ready through transient sensor drops.
        if sessionLatched {
            return .ready(name: connectedName(trainer))
        }

        // Before the latch: waiting on the trainer's ERG handshake and, if
        // required, the HR strap.
        if mirroredTrainerReady {
            return .preparing   // ready conditions not fully met yet (e.g. HR)
        }

        switch trainer {
        case .disconnected: return .scanning
        case .scanning:     return .scanning
        case .connecting(let name): return .connecting(name: name)
        case .connected:    return .preparing   // handshake in progress
        }
    }

    // MARK: - Control

    /// Start a ride session: scan for the trainer, the power meter, plus HR if
    /// required. The power meter is always scanned for but never required — it
    /// connects silently if present and is simply absent otherwise (same pattern
    /// as an HR strap when HR isn't required). It feeds the ride screen's
    /// secondary readout, records leg power on its own channel, and can supply
    /// the TCX export's watts (see `TCXPowerSource`), but never drives ERG or
    /// the zone math; the ride starts on the trainer alone.
    public func connect() {
        var kinds: Set<SensorKind> = [.trainer, .powerMeter]
        if requiresHeartRate { kinds.insert(.heartRate) }
        hub.connect(kinds)
    }

    public func setTargetPower(_ watts: Int) { hub.setTargetPower(watts) }

    /// Expire the power meter's reading if it has gone stale — see
    /// `SensorHub.sweepStalePowerMeter`. Driven by the ride screen's 1 Hz
    /// recording tick, so a quiet meter clears on its own clock rather than
    /// depending on some other sensor still reporting to sweep it.
    public func sweepStalePowerMeter() { hub.sweepStalePowerMeter() }

    // MARK: - Device browsing & preferred selection

    /// Begin a discovery scan for `kind`, populating `discovered`. Use from the
    /// setup screen to let the rider pick a preferred device; call
    /// `stopBrowsing()` when the picker closes.
    public func startBrowsing(_ kind: SensorKind) { hub.startBrowsing(kind) }

    /// Stop the browse scan and clear `discovered`.
    public func stopBrowsing() { hub.stopBrowsing() }

    /// The rider's pinned device for `kind`, if any.
    public func preferredIdentifier(for kind: SensorKind) -> UUID? {
        hub.preferredIdentifier(for: kind)
    }

    /// Pin (or clear, with nil) the preferred device for `kind`. When set, only
    /// that device is used for the kind; others are ignored.
    public func setPreferred(_ identifier: UUID?, for kind: SensorKind) {
        hub.setPreferred(identifier, for: kind)
    }

    public func stop() {
        sessionLatched = false
        hub.stop()
        // Mirror the reset immediately so `connection` reports `.idle` without
        // waiting for a callback.
        syncState()
        metrics = RideMetrics()
    }

    private func connectedName(_ state: SensorConnectionState) -> String {
        if case .connected(let name) = state { return name }
        return "Trainer"
    }

    #if DEBUG
    /// Test seam: the hub this controller wraps, so tests can drive
    /// connection-state changes via `SensorHub`'s own DEBUG test seams
    /// without a CoreBluetooth central.
    var hubForTesting: SensorHub { hub }
    #endif
}
