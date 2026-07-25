import Testing
@testable import ZonaKit

struct PowerPerWeightTests {
    @Test func dividesWattsByWeight() {
        #expect(PowerPerWeight.wattsPerKg(watts: 150, weightKg: 75) == 2.0)
    }

    @Test func nilWhenWattsMissing() {
        #expect(PowerPerWeight.wattsPerKg(watts: nil, weightKg: 75) == nil)
    }

    @Test func nilWhenWeightMissing() {
        #expect(PowerPerWeight.wattsPerKg(watts: 150, weightKg: nil) == nil)
    }

    @Test func nilWhenWeightZeroOrNegative() {
        #expect(PowerPerWeight.wattsPerKg(watts: 150, weightKg: 0) == nil)
        #expect(PowerPerWeight.wattsPerKg(watts: 150, weightKg: -5) == nil)
    }
}
