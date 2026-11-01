import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Models the user added: any MLX repo on Hugging Face, or a model folder imported from the Files app.
enum CustomModels {
    private struct Entry: Codable {
        var id: String
        var name: String
        var weightsGB: Double
        var license: String
        var localPath: String?
    }
    private static let key = "models.custom"

    static func load() -> [CuratedModel] {
        let entries = (UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
        return entries.map {
            CuratedModel(family: "Your models", id: $0.id, name: $0.name, weightsGB: $0.weightsGB, capabilities: [.general],
                         license: $0.license, runtimeReady: true, note: $0.localPath == nil ? "Added from Hugging Face." : "Imported from Files.", localPath: $0.localPath)
        }
    }

    private static func save(_ entries: [Entry]) { UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: key) }
    private static func entries() -> [Entry] { (UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? [] }

    static func remove(_ id: String) {
        var all = entries()
        if let entry = all.first(where: { $0.id == id }), let path = entry.localPath { try? FileManager.default.removeItem(atPath: path) }
        all.removeAll { $0.id == id }
        save(all)
    }

    /// Looks the repo up on Hugging Face and adds it. Throws if it isn't an MLX model.
    static func addFromHub(repo rawRepo: String) async throws {
        let repo = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "https://huggingface.co/", with: "")
        guard repo.split(separator: "/").count == 2, let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true") else {
            throw RemoteError(message: "Enter a repo like mlx-community/Qwen3-4B-4bit.")
        }
        let (data, response) = try await AppNet.session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw RemoteError(message: "Couldn't find that repo. Private or gated repos aren't supported yet.")
        }
        let files = json["siblings"]?.array ?? []
        let names = files.compactMap { $0["rfilename"]?.string }
        guard names.contains("config.json"), names.contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw RemoteError(message: "That repo doesn't look like an MLX model (no config.json and .safetensors files).")
        }
        let bytes = files.compactMap { $0["size"]?.int }.reduce(0, +)
        let license = (json["tags"]?.array ?? []).compactMap(\.string).first { $0.hasPrefix("license:") }?.dropFirst(8) ?? "see model page"
        var all = entries()
        all.removeAll { $0.id == repo }
        all.append(Entry(id: repo, name: String(repo.split(separator: "/").last ?? ""), weightsGB: Double(bytes) / 1e9, license: String(license), localPath: nil))
        save(all)
    }

    /// Copies a model folder picked in Files into the app and registers it.
    static func importFolder(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.appending(path: "config.json").path) else {
            throw RemoteError(message: "That folder has no config.json. Pick the folder that holds the model files.")
        }
        var dir = URL.applicationSupportDirectory.appending(path: "Models/Imported", directoryHint: .isDirectory)
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appending(path: source.lastPathComponent)
        try? manager.removeItem(at: destination)
        try manager.copyItem(at: source, to: destination)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let size = (manager.enumerator(at: destination, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { (try? ($0 as? URL)?.resourceValues(forKeys: [.fileSizeKey]))??.fileSize } ?? []).reduce(0, +)
        var all = entries()
        let id = "local/" + source.lastPathComponent
        all.removeAll { $0.id == id }
        all.append(Entry(id: id, name: source.lastPathComponent, weightsGB: Double(size) / 1e9, license: "unknown", localPath: destination.path))
        save(all)
    }
}

struct AddModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdded: () -> Void
    @State private var repo = ""
    @State private var busy = false
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mlx-community/Qwen3-4B-4bit", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(busy ? "Checking…" : "Add from Hugging Face", systemImage: "plus.circle") {
                        Task {
                            busy = true; error = nil
                            do { try await CustomModels.addFromHub(repo: repo); onAdded(); dismiss() } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.disabled(repo.isEmpty || busy)
                } header: { Text("Hugging Face") } footer: { Text("Any public MLX-format model. It downloads when you first use it. Check its license on the model page.") }
                Section {
                    Button("Import a model folder…", systemImage: "folder") { importing = true }
                } header: { Text("Files") } footer: { Text("A folder with config.json and .safetensors weights, e.g. from iCloud Drive.") }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Add a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do { try CustomModels.importFolder(url); onAdded(); dismiss() } catch { self.error = error.localizedDescription }
                case .failure(let e): error = e.localizedDescription
                }
            }
        }
    }
}
