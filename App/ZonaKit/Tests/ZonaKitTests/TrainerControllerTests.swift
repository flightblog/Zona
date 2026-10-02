import Foundation
import Testing
@testable import ZonaKit

/// Exercises `TrainerController`'s connection-state derivation and ride-start
/// latch logic by driving its wrapped `SensorHub` through DEBUG test seams —
/// no CoreBluetooth central involved, matching the pattern `SensorTests`
/// already uses for metrics via `applyForTesting`.
@Suite("Trainer controller")
@MainActor
struct TrainerControllerTests {
    @Test func startsIdleBeforeConnecting() {
        let controller = TrainerController()
        #expect(controller.connection == .idle)
        #expect(controller.sessionLatched == false)
    }

    @Test func scanningOnceDesiredKindsAreSet() {
        let controller = TrainerController()
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer, .powerMeter])
        hub.setStateForTesting(.scanning, for: .trainer)
        #expect(controller.connection == .scanning)
    }

    @Test func connectingSurfacesTrainerName() {
        let controller = TrainerController()
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer])
        hub.setStateForTesting(.connecting(name: "Kickr Core 2"), for: .trainer)
        #expect(controller.connection == .connecting(name: "Kickr Core 2"))
    }

    @Test func preparingAfterTrainerConnectsButBeforeERGReady() {
        let controller = TrainerController()
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer])
        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        #expect(controller.connection == .preparing)
        #expect(controller.sessionLatched == false)
    }

    @Test func readyOnceLatchedWithoutHeartRateRequirement() {
        let controller = TrainerController()
        controller.requiresHeartRate = false
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer])
        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        hub.setTrainerReadyForTesting()
        #expect(controller.sessionLatched == true)
        #expect(controller.connection == .ready(name: "Kickr Core 2"))
    }

    /// The documented gate: starting a ride requires HR when `requiresHeartRate`
    /// is set — the trainer alone being ready isn't enough to latch.
    @Test func latchWaitsForHeartRateWhenRequired() {
        let controller = TrainerController()
        controller.requiresHeartRate = true
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer, .heartRate])
        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        hub.setTrainerReadyForTesting()
        #expect(controller.sessionLatched == false)
        #expect(controller.connection == .preparing)

        hub.setStateForTesting(.connected(name: "Garmin HRM 200"), for: .heartRate)
        #expect(controller.sessionLatched == true)
        #expect(controller.connection == .ready(name: "Kickr Core 2"))
    }

    /// The documented latch behavior: once a ride has started, a transient HR
    /// strap drop (they disconnect on idle) must not eject back to setup.
    @Test func latchStaysTrueThroughTransientHeartRateDrop() {
        let controller = TrainerController()
        controller.requiresHeartRate = true
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer, .heartRate])
        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        hub.setStateForTesting(.connected(name: "Garmin HRM 200"), for: .heartRate)
        hub.setTrainerReadyForTesting()
        #expect(controller.sessionLatched == true)

        hub.setStateForTesting(.disconnected, for: .heartRate)
        #expect(controller.sessionLatched == true)
        #expect(controller.connection == .ready(name: "Kickr Core 2"))
    }

    @Test func sensorStateDefaultsToDisconnected() {
        let controller = TrainerController()
        #expect(controller.sensorState(.trainer) == .disconnected)
        #expect(controller.sensorState(.heartRate) == .disconnected)
    }

    @Test func sensorStateReflectsHubPerKindState() {
        let controller = TrainerController()
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer, .heartRate])
        hub.setStateForTesting(.connecting(name: "Kickr Core 2"), for: .trainer)
        #expect(controller.sensorState(.trainer) == .connecting(name: "Kickr Core 2"))
        #expect(controller.sensorState(.heartRate) == .scanning)
    }

    @Test func stopResetsConnectionAndClearsLatch() {
        let controller = TrainerController()
        controller.requiresHeartRate = false
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer])
        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        hub.setTrainerReadyForTesting()
        #expect(controller.sessionLatched == true)

        controller.stop()
        #expect(controller.sessionLatched == false)
        #expect(controller.connection == .idle)
        #expect(controller.metrics.powerW == nil)
        #expect(controller.sensorState(.trainer) == .disconnected)
    }

    // MARK: - ERG target across a trainer drop

    private static func targetCommand(_ watts: Int) -> Data {
        FTMS.setTargetPowerCommand(watts: watts)
    }

    /// A controller mid-ride: trainer connected, handshake done, latched.
    private static func ridingController() -> (TrainerController, SensorHub) {
        let controller = TrainerController()
        controller.requiresHeartRate = false
        let hub = controller.hubForTesting
        hub.setDesiredKindsForTesting([.trainer])
        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        hub.setTrainerReadyForTesting()
        return (controller, hub)
    }

    /// The handshake carries no target, so a reconnect must re-send the one
    /// the ride was holding — otherwise ERG resumes on whatever the trainer kept.
    @Test func reconnectRestoresTheTargetTheRideWasHolding() {
        let (controller, hub) = Self.ridingController()
        controller.setTargetPower(180)

        hub.setStateForTesting(.scanning, for: .trainer)
        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        hub.setTrainerReadyForTesting()

        #expect(hub.trainerWritesForTesting == [Self.targetCommand(180), Self.targetCommand(180)])
    }

    /// A target set while the trainer is gone (an interval step, a revert, a
    /// trim) must reach the trainer on reconnect, not vanish into a write with
    /// no control point — and nothing may be "sent" while it's down.
    @Test func targetSetDuringDropIsHeldThenAppliedOnReconnect() {
        let (controller, hub) = Self.ridingController()
        controller.setTargetPower(180)
        hub.setStateForTesting(.scanning, for: .trainer)
        #expect(hub.trainerReady == false)

        controller.setTargetPower(250)
        #expect(controller.metrics.targetW == 250)
        #expect(hub.trainerWritesForTesting == [Self.targetCommand(180)])

        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        #expect(hub.trainerWritesForTesting == [Self.targetCommand(180)])  // still handshaking
        hub.setTrainerReadyForTesting()
        #expect(hub.trainerWritesForTesting == [Self.targetCommand(180), Self.targetCommand(250)])
    }

    /// The drop clears readiness but must not eject the rider from the ride.
    @Test func trainerDropClearsReadinessButKeepsTheRideLatched() {
        let (controller, hub) = Self.ridingController()
        hub.setStateForTesting(.connecting(name: "Kickr Core 2"), for: .trainer)
        #expect(hub.trainerReady == false)
        #expect(controller.sessionLatched == true)
        // Still the ride screen (the name falls back while the link is down).
        guard case .ready = controller.connection else {
            Issue.record("expected .ready, got \(controller.connection)")
            return
        }
    }

    /// The first handshake has no target to restore — the ride screen sets it.
    @Test func firstHandshakeSendsNoTarget() {
        let (_, hub) = Self.ridingController()
        #expect(hub.trainerWritesForTesting.isEmpty)
    }

    /// `stop` forgets the target, so the next ride's handshake doesn't replay
    /// the previous ride's watts before its own screen sets one.
    @Test func stopForgetsTheTarget() {
        let (controller, hub) = Self.ridingController()
        controller.setTargetPower(180)
        controller.stop()

        hub.setDesiredKindsForTesting([.trainer])
        hub.setStateForTesting(.connected(name: "Kickr Core 2"), for: .trainer)
        hub.setTrainerReadyForTesting()
        #expect(hub.trainerWritesForTesting == [Self.targetCommand(180), FTMS.stopCommand()])
    }
}
