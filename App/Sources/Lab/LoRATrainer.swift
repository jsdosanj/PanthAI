import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXOptimizers
import Observation
import UIKit

/// On-device LoRA fine-tuning of a small downloaded model on the user's own text.
/// Experimental: it needs the screen on and the app in front, and it heats the iPad.
@MainActor @Observable
final class LoRATrainer {
    static let shared = LoRATrainer()

    struct Settings {
        var iterations = 100
        var batchSize = 1
        var layers = 4
        var rank = 8
        var learningRate = 1e-5
    }

    private(set) var running = false
    private(set) var log: [String] = []
    private(set) var lastLoss: Float?
    var finishedAdapter: String?
    @ObservationIgnored private let stopFlag = Flag()

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        var isSet: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    static var adaptersFolder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Adapters", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func adapterDirectory(model: String, name: String) -> URL {
        adaptersFolder.appending(path: model.replacingOccurrences(of: "/", with: "__")).appending(path: name)
    }

    func stop() { stopFlag.isSet = true }

    /// Trains on a JSONL file where each line is {"text": "..."}.
    func train(model: CuratedModel, dataset: URL, adapterName: String, settings: Settings) async {
        guard !running else { return }
        running = true; log = ["Loading \(model.name)…"]; lastLoss = nil; finishedAdapter = nil; stopFlag.isSet = false
        UIApplication.shared.isIdleTimerDisabled = true
        defer { running = false; UIApplication.shared.isIdleTimerDisabled = false }

        await ModelManager.shared.ensureLoaded(model)
        guard let container = ModelManager.shared.container(for: model) else { log.append("Couldn't load the model."); return }

        let scoped = dataset.startAccessingSecurityScopedResource()
        defer { if scoped { dataset.stopAccessingSecurityScopedResource() } }
        guard let all = try? loadLoRAData(url: dataset), all.count >= 4 else { log.append("The file needs at least 4 lines like {\"text\": \"…\"}."); return }
        let shuffled = all.shuffled()
        let cut = max(1, shuffled.count / 10)
        let validation = Array(shuffled.prefix(cut)), training = Array(shuffled.dropFirst(cut))
        log.append("\(training.count) training and \(validation.count) validation examples.")

        let directory = Self.adapterDirectory(model: model.id, name: adapterName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let flag = stopFlag
        let post: @Sendable (String, Float?) -> Void = { text, loss in Task { @MainActor in LoRATrainer.shared.log.append(text); if let loss { LoRATrainer.shared.lastLoss = loss } } }
        let s = settings

        do {
            try await container.perform { context in
                let configuration = LoRAConfiguration(numLayers: s.layers, fineTuneType: .lora,
                                                      loraParameters: .init(rank: s.rank, scale: 20, dropout: 0, keys: nil))
                _ = try LoRAContainer.from(model: context.model, configuration: configuration)
                let optimizer = Adam(learningRate: Float(s.learningRate))
                let parameters = LoRATrain.Parameters(batchSize: s.batchSize, iterations: s.iterations, stepsPerReport: 5, stepsPerEval: 50,
                                                      validationBatches: 5, saveEvery: 50, adapterURL: directory.appending(path: "adapters.safetensors"))
                try LoRATrain.train(model: context.model, train: training, validate: validation, optimizer: optimizer,
                                    tokenizer: context.tokenizer, parameters: parameters) { progress in
                    switch progress {
                    case .train(let iteration, let loss, _, let tps): post("step \(iteration): loss \(String(format: "%.3f", loss)) · \(Int(tps)) tok/s", loss)
                    case .validation(let iteration, let loss, _): post("step \(iteration): validation loss \(String(format: "%.3f", loss))", nil)
                    case .save: post("checkpoint saved", nil)
                    }
                    return flag.isSet ? .stop : .more
                }
                try LoRATrain.saveLoRAWeights(model: context.model, url: directory.appending(path: "adapters.safetensors"))
                try JSONEncoder().encode(configuration).write(to: directory.appending(path: "adapter_config.json"))
            }
            log.append(stopFlag.isSet ? "Stopped. Adapter saved." : "Done. Adapter saved.")
            finishedAdapter = adapterName
            UserDefaults.standard.set(directory.path, forKey: "adapter.\(model.id)")
            await ModelManager.shared.reloadAfterTraining(model)   // fresh copy of the base model, now with the adapter applied
        } catch {
            log.append("Training failed: \(error.localizedDescription)")
        }
    }
}
