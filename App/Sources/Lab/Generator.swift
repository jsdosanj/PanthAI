import Foundation
import MachO
import SwiftData
import SwiftUI

/// Runs one prompt on one model with no chat around it. Used by Benchmark, Compare and Evals.
@MainActor
enum Generator {
    struct Result {
        var text = ""
        var loadSeconds: Double?
        var firstTokenSeconds: Double?
        var totalSeconds = 0.0
        var error: String?
        var peakFootprintGB: Double?
        var thermal = ProcessInfo.processInfo.thermalState

        var approxTokens: Int { text.count / 4 }
        var tokensPerSecond: Double? {
            guard let first = firstTokenSeconds, totalSeconds > first, approxTokens > 0 else { return nil }
            return Double(approxTokens) / (totalSeconds - first)
        }
    }

    static func footprintGB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_073_741_824 : 0
    }

    static func run(_ choice: ProviderChoice, prompt: String, sampling: SamplingSettings = SamplingSettings(),
                    onPartial: ((String) -> Void)? = nil) async -> Result {
        var result = Result()
        if case .mlx(let repo) = choice, let model = CuratedModels.find(repo) {
            let loadStart = Date()
            await ModelManager.shared.ensureLoaded(model)
            result.loadSeconds = Date().timeIntervalSince(loadStart)
        }
        guard let provider = ChatViewModel.makeProvider(for: choice) else { result.error = "Model not available."; return result }
        let started = Date()
        var peak = footprintGB()
        do {
            for try await text in provider.stream(prompt: prompt, history: [], kind: .chat, extraInstructions: "", sampling: sampling) {
                if result.firstTokenSeconds == nil { result.firstTokenSeconds = Date().timeIntervalSince(started) }
                let (clipped, stopped) = sampling.applyStops(text)
                result.text = clipped
                peak = max(peak, footprintGB())
                onPartial?(clipped)
                if stopped { break }
            }
        } catch { result.error = error.localizedDescription }
        result.totalSeconds = Date().timeIntervalSince(started)
        result.peakFootprintGB = peak
        result.thermal = ProcessInfo.processInfo.thermalState
        if case .mlx(let repo) = choice, result.error == nil { MeasuredFootprints.record(repo, gb: peak) }
        return result
    }
}

/// Real memory use seen during runs, so the compatibility badges can learn from this iPad.
enum MeasuredFootprints {
    private static let key = "models.measuredFootprint"
    static func record(_ id: String, gb: Double) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[id] = max(all[id] ?? 0, gb)
        UserDefaults.standard.set(all, forKey: key)
    }
    static func value(_ id: String) -> Double? { (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[id] }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

enum ModelPool {
    /// Everything the user could run: Apple, downloaded models, and models on connected providers.
    @MainActor static func options(providers: [ProviderRecord]) -> [ProviderChoice] {
        var list: [ProviderChoice] = [.apple(.onDevice), .apple(.privateCloud)]
        list += CuratedModels.everything.filter { ModelManager.shared.isDownloaded($0.id) }.map { .mlx($0.id) }
        for provider in providers { list += provider.models.prefix(15).map { .remote(provider.id, $0) } }
        return list
    }
}

/// A multi-select list of models.
struct ModelMultiPicker: View {
    let options: [ProviderChoice]
    @Binding var selection: Set<ProviderChoice>

    var body: some View {
        ForEach(options, id: \.self) { choice in
            Button {
                if selection.contains(choice) { selection.remove(choice) } else { selection.insert(choice) }
            } label: {
                HStack {
                    Text(choice.label)
                    Spacer()
                    if selection.contains(choice) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
            }
            .foregroundStyle(.primary)
        }
    }
}

enum CSV {
    static func escape(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func file(named name: String, rows: [[String]]) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
