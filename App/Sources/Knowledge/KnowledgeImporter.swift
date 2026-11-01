import Foundation
import Observation
import PhotosUI
import SwiftUI

/// Adds files, photos and dropped items to Knowledge, one at a time, off the main thread.
@MainActor @Observable
final class KnowledgeImporter {
    static let shared = KnowledgeImporter()
    private(set) var working = 0
    var message: String?

    func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()   // dropped and picked files need this until we've read them
            let name = url.lastPathComponent
            run(name) {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return (name, try TextExtractor.extract(fileAt: url))
            }
        }
    }

    func importPhotos(_ items: [PhotosPickerItem]) {
        for (i, item) in items.enumerated() {
            let name = "Photo \(Date.now.formatted(date: .abbreviated, time: .shortened))" + (items.count > 1 ? " (\(i + 1))" : "")
            working += 1
            Task {
                defer { working -= 1 }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw KnowledgeError("That photo couldn't be loaded.") }
                    let document = try await Task.detached(priority: .utility) { try TextExtractor.extract(data: data, name: name + ".jpg") }.value
                    try await finish(name: name, document: document)
                } catch { message = error.localizedDescription }
            }
        }
    }

    private func run(_ label: String, _ work: @escaping @Sendable () throws -> (String, ExtractedDocument)) {
        working += 1
        Task {
            defer { working -= 1 }
            do {
                let (name, document) = try await Task.detached(priority: .utility, operation: work).value
                try await finish(name: name, document: document)
            } catch { message = "\(label): \(error.localizedDescription)" }
        }
    }

    private func finish(name: String, document: ExtractedDocument) async throws {
        switch try await KnowledgeIndex.shared.add(name: name, document: document) {
        case .added(let passages): message = "Added \(name) (\(passages) passage\(passages == 1 ? "" : "s"))."
        case .duplicate: message = "\(name) is already in Knowledge."
        }
    }
}
