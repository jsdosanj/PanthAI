import Foundation

enum Compatibility: String, Sendable, CaseIterable {
    case great, runs, tight, wontFit

    var label: String {
        switch self {
        case .great: "Runs great"
        case .runs: "Runs"
        case .tight: "Tight fit"
        case .wontFit: "Won't fit"
        }
    }

    var systemImage: String {
        switch self {
        case .great: "checkmark.circle.fill"
        case .runs: "checkmark.circle"
        case .tight: "exclamationmark.triangle.fill"
        case .wontFit: "xmark.octagon.fill"
        }
    }
}

enum CompatibilityEstimator {
    /// Weights plus runtime overhead plus a KV-cache allowance.
    static func footprintGB(weightsGB: Double, contextTokens: Int = 4096) -> Double {
        let kvAllowanceGB = 0.25 + weightsGB * 0.05 * Double(contextTokens) / 4096
        return weightsGB * 1.1 + kvAllowanceGB
    }

    static func rate(measuredGB: Double, on device: DeviceProfile = .current) -> Compatibility {
        switch measuredGB / device.modelBudgetGB {
        case ..<0.5: return .great
        case ..<0.85: return .runs
        case ..<1.0: return .tight
        default: return .wontFit
        }
    }

    static func rate(weightsGB: Double, on device: DeviceProfile = .current) -> Compatibility {
        let need = footprintGB(weightsGB: weightsGB)
        let budget = device.modelBudgetGB
        switch need / budget {
        case ..<0.5: return .great
        case ..<0.85: return .runs
        case ..<1.0: return .tight
        default: return .wontFit
        }
    }
}
