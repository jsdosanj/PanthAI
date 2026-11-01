import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Observation
import Tokenizers

enum ModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(fraction: Double)
    case ready
    case failed(String)
}

/// Owns download state and the single resident MLX model.
/// Weights live in Application Support (not Caches, which iPadOS may purge)
/// and are excluded from iCloud backup.
@MainActor @Observable
final class ModelManager {
    static let shared = ModelManager()

    private(set) var states: [String: ModelState] = [:]
    private(set) var residentModelID: String?
    private var container: ModelContainer?
    private var loadTask: Task<Void, Never>?

    private let hub: HubClient
    private static let downloadedKey = "models.downloaded"
    private(set) var downloaded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: ModelManager.downloadedKey) ?? [])

    func isDownloaded(_ id: String) -> Bool { downloaded.contains(id) }

    private init() {
        var dir = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        hub = HubClient(session: AppNet.session, cache: HubCache(cacheDirectory: dir))
        refreshCatalog()
    }

    func state(of id: String) -> ModelState { states[id] ?? .notDownloaded }

    /// Call after models are added or removed.
    func refreshCatalog() {
        for model in CuratedModels.everything where states[model.id] == nil { states[model.id] = downloaded.contains(model.id) ? .ready : .notDownloaded }
    }

    /// Downloads (if needed) and loads the model, making it the resident model.
    func load(_ model: CuratedModel) {
        guard loadTask == nil else { return }
        if model.compatibility == .wontFit {
            states[model.id] = .failed("This model needs more memory than this iPad can give it.")
            return
        }
        states[model.id] = .downloading(fraction: 0)
        loadTask = Task {
            defer { loadTask = nil }
            do {
                container = nil   // free the previous model before loading another
                residentModelID = nil
                if let path = model.localPath {
                    let local = try await loadModelContainer(from: URL(filePath: path), using: #huggingFaceTokenizerLoader())
                    container = local
                    residentModelID = model.id
                    states[model.id] = .ready
                    downloaded.insert(model.id)
                    UserDefaults.standard.set(Array(downloaded), forKey: Self.downloadedKey)
                    return
                }
                if let path = model.localPath {
                    let local = try await loadModelContainer(from: URL(filePath: path), using: #huggingFaceTokenizerLoader())
                    container = local
                    residentModelID = model.id
                    states[model.id] = .ready
                    downloaded.insert(model.id)
                    UserDefaults.standard.set(Array(downloaded), forKey: Self.downloadedKey)
                    return
                }
                let loaded = try await loadModelContainer(
                    from: #hubDownloader(hub),
                    using: #huggingFaceTokenizerLoader(),
                    id: model.id,
                    progressHandler: { progress in
                        Task { @MainActor in
                            ModelManager.shared.states[model.id] = .downloading(fraction: progress.fractionCompleted)
                        }
                    })
                if let path = UserDefaults.standard.string(forKey: "adapter.\(model.id)") {
                    try? await loaded.perform { context in try LoRAContainer.from(directory: URL(filePath: path)).load(into: context.model) }
                }
                container = loaded
                residentModelID = model.id
                states[model.id] = .ready
                downloaded.insert(model.id)
                UserDefaults.standard.set(Array(downloaded), forKey: Self.downloadedKey)
            } catch {
                states[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Loads a model (from disk if already downloaded) and waits until it is resident.
    func ensureLoaded(_ model: CuratedModel) async {
        if residentModelID == model.id { return }
        await loadTask?.value
        if residentModelID == model.id { return }
        load(model)
        await loadTask?.value
    }

    func container(for model: CuratedModel) -> ModelContainer? { residentModelID == model.id ? container : nil }

    /// After fine-tuning, drop the trained-in-place copy and load a clean one with the saved adapter.
    func reloadAfterTraining(_ model: CuratedModel) async {
        container = nil
        residentModelID = nil
        await ensureLoaded(model)
    }

    func makeProvider(for model: CuratedModel) -> MLXProvider? {
        guard residentModelID == model.id, let container else { return nil }
        return MLXProvider(name: model.name, container: container)
    }
}
