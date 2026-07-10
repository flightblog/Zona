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
}
