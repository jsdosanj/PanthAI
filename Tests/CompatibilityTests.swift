import Testing
@testable import DosanjhAI

struct CompatibilityTests {
    private let ipad8 = DeviceProfile(physicalMemoryBytes: 8 * 1_073_741_824)
    private let ipad16 = DeviceProfile(physicalMemoryBytes: 16 * 1_073_741_824)

    @Test func smallModelRunsGreatOn8GB() {
        #expect(CompatibilityEstimator.rate(weightsGB: 0.98, on: ipad8) == .great)
    }

    @Test func eightBillionDoesNotFit8GB() {
        #expect(CompatibilityEstimator.rate(weightsGB: 8.3, on: ipad8) == .wontFit)
    }

    @Test func sixteenGBHoldsBigVisionModel() {
        #expect(CompatibilityEstimator.rate(weightsGB: 5.78, on: ipad16) != .wontFit)
    }

    @Test func recommendedExcludesWontFit() {
        for model in CuratedModels.recommended(for: ipad8) {
            #expect(CompatibilityEstimator.rate(weightsGB: model.weightsGB, on: ipad8) != .wontFit)
        }
    }
}
