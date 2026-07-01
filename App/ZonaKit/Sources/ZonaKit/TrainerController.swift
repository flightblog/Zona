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

    // NOT @ObservationIgnored: `SensorHub` is itself `@Observable`, and the
    // computed `connection`/`metrics` read its stored properties. Leaving this
    // observed lets SwiftUI register those nested reads as dependencies, so the
    // UI re-renders exactly when the hub's state changes — not at arbitrary
    // times (which caused the setup↔ride screen bounce).
    private let hub: SensorHub

    public init(memory: SensorMemory = EphemeralSensorMemory()) {
        self.hub = SensorHub(memory: memory)
        // Latch the ride as started as soon as the start conditions are met.
        self.hub.onStateChange = { [weak self] in self?.updateLatch() }
    }

    // MARK: - Published, view-facing state (derived from the hub)

    /// Live merged metrics across all connected sensors.
    public var metrics: RideMetrics { hub.metrics }

    /// Per-sensor connection state, for setup rows.
    public func sensorState(_ kind: SensorKind) -> SensorConnectionState {
        hub.state(for: kind)
    }

    public var log: [String] { hub.log }

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
        guard !sessionLatched, hub.trainerReady else { return }
        if requiresHeartRate && !hub.state(for: .heartRate).isConnected { return }
        sessionLatched = true
    }

    /// Collapsed lifecycle state the top-level UI switches on. Maps the hub's
    /// per-sensor states into the existing `ConnectionState` the views use.
    /// Pure read — no mutation.
    public var connection: ConnectionState {
        let trainer = hub.state(for: .trainer)

        // Nothing started yet.
        if hub.desiredKinds.isEmpty { return .idle }

        // Once a ride has started, stay ready through transient sensor drops.
        if sessionLatched {
            return .ready(name: connectedName(trainer))
        }

        // Before the latch: waiting on the trainer's ERG handshake and, if
        // required, the HR strap.
        if hub.trainerReady {
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

    /// Start a ride session: scan for the trainer, plus HR if required.
    public func connect() {
        var kinds: Set<SensorKind> = [.trainer]
        if requiresHeartRate { kinds.insert(.heartRate) }
        hub.connect(kinds)
    }

    public func setTargetPower(_ watts: Int) { hub.setTargetPower(watts) }

    public func stop() {
        sessionLatched = false
        hub.stop()
    }

    private func connectedName(_ state: SensorConnectionState) -> String {
        if case .connected(let name) = state { return name }
        return "Trainer"
    }
}
