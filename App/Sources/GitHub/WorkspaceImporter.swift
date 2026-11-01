import Foundation
import SwiftData

/// A GitHub repo snapshot downloaded into the app container, attachable to code sessions.
@Model
final class WorkspaceRecord {
    var id: UUID = UUID()
    var fullName: String = ""
    var branch: String = ""
    var folderName: String = ""
    var fileCount: Int = 0
    var totalBytes: Int = 0
    var truncated: Bool = false
    var importedAt: Date = Date.now

    init(fullName: String, branch: String, folderName: String) {
        self.fullName = fullName
        self.branch = branch
        self.folderName = folderName
    }

    var displayName: String { "\(fullName)@\(branch)" }
    var folderURL: URL { WorkspaceFiles.root.appending(path: folderName, directoryHint: .isDirectory) }
}

enum WorkspaceFiles {
    static var root: URL {
        var url = URL.applicationSupportDirectory.appending(path: "Workspaces", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    static func paths(in workspace: WorkspaceRecord) -> [String] { paths(at: workspace.folderURL) }

    static func paths(at base: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let relative = String(url.path.dropFirst(base.path.count + 1))
            if !relative.hasPrefix(".dosanjhai") { result.append(relative) }
        }
        return result.sorted()
    }

    static func read(_ path: String, in workspace: WorkspaceRecord) -> String? {
        guard !path.contains("..") else { return nil }   // never leave the workspace folder
        return try? String(contentsOf: workspace.folderURL.appending(path: path), encoding: .utf8)
    }
}

enum WorkspaceImporter {
    static let ignoredDirectories: Set<String> = [".git", "node_modules", "Pods", "build", "DerivedData", ".build", "vendor", "dist", ".next", "__pycache__"]
    static let binaryExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "pdf", "zip", "gz", "tar", "mp3", "mp4", "mov", "woff", "woff2", "ttf", "otf", "ico", "icns", "a", "dylib", "o", "bin", "mlmodel", "safetensors", "gguf"]
    static let maxFileBytes = 200_000
    static let maxFiles = 400
    static let maxTotalBytes = 12_000_000

    struct Result: Sendable { let fileCount: Int; let totalBytes: Int; let truncated: Bool }

    /// What the repo looked like when downloaded, so git tools can tell what changed.
    struct Manifest: Codable, Sendable {
        var fullName: String
        var baseBranch: String      // branch this snapshot came from (pull requests target it)
        var branch: String          // branch commits go to
        var headCommit: String
        var headTree: String
        var shas: [String: String]  // path -> git blob sha at head
    }

    static func manifestURL(_ root: URL) -> URL { root.appending(path: ".dosanjhai/manifest.json") }
    static func loadManifest(_ root: URL) -> Manifest? {
        (try? Data(contentsOf: manifestURL(root))).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }
    static func saveManifest(_ manifest: Manifest, root: URL) throws {
        try FileManager.default.createDirectory(at: manifestURL(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: manifestURL(root))
    }

    static func eligible(_ entries: [GitHubTreeEntry]) -> (files: [GitHubTreeEntry], truncated: Bool) {
        var total = 0
        var kept: [GitHubTreeEntry] = []
        var truncated = false
        for entry in entries where entry.type == "blob" {
            let parts = entry.path.split(separator: "/").map(String.init)
            if parts.dropLast().contains(where: ignoredDirectories.contains) { continue }
            if binaryExtensions.contains((entry.path as NSString).pathExtension.lowercased()) { continue }
            let size = entry.size ?? 0
            if size > maxFileBytes { truncated = true; continue }
            if kept.count >= maxFiles || total + size > maxTotalBytes { truncated = true; continue }
            total += size
            kept.append(entry)
        }
        return (kept, truncated)
    }

    /// Downloads the repo's text files at `branch` into `destination`.
    static func download(fullName: String, branch: String, to destination: URL, client: GitHubClient = .init(),
                         progress: @Sendable @escaping (Double) -> Void) async throws -> Result {
        let head = try? await client.head(fullName, branch: branch)
        let (files, truncated) = eligible(try await client.tree(fullName, ref: head?.commit ?? branch))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var done = 0
        var bytes = 0
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var iterator = files.makeIterator()
            func addNext() {
                guard let entry = iterator.next() else { return }
                group.addTask { (entry.path, try await client.blob(fullName, sha: entry.sha)) }
            }
            for _ in 0..<8 { addNext() }            // 8 downloads at a time
            while let (path, data) = try await group.next() {
                let url = destination.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                done += 1; bytes += data.count
                progress(Double(done) / Double(max(files.count, 1)))
                addNext()
            }
        }
        if let head {
            let shas = Dictionary(files.map { ($0.path, $0.sha) }, uniquingKeysWith: { $1 })
            try saveManifest(Manifest(fullName: fullName, baseBranch: branch, branch: branch, headCommit: head.commit, headTree: head.tree, shas: shas), root: destination)
        }
        return Result(fileCount: done, totalBytes: bytes, truncated: truncated)
    }
}
