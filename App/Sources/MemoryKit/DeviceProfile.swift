import Foundation

/// What this iPad can hold in memory. Drives the compatibility badges and
/// the load-time guard that refuses models that would get the app jetsammed.
struct DeviceProfile: Sendable, Equatable {
    let physicalMemoryBytes: UInt64

    static var current: DeviceProfile {
        DeviceProfile(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    var physicalMemoryGB: Double { Double(physicalMemoryBytes) / 1_073_741_824 }

    /// Fraction of RAM we plan to use for a resident model. PROVISIONAL:
    /// replace with measured values from on-device testing (plan §6.2).
    static let usableFraction = 0.6

    var modelBudgetGB: Double { physicalMemoryGB * Self.usableFraction }
}
