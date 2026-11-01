import Foundation
import SwiftData

/// A document or photo the user added to Knowledge. Only the extracted text is kept, never the original file.
@Model
final class KnowledgeSource {
    var id: UUID = UUID()
    var name: String = ""
    var kind: String = "text"          // text, pdf, image
    var addedAt: Date = Date.now
    var characters: Int = 0
    var chunkCount: Int = 0
    var contentHash: String = ""
    var note: String = ""              // e.g. "Text read from the image"

    init(name: String, kind: String, characters: Int, chunkCount: Int, contentHash: String, note: String) {
        self.name = name; self.kind = kind; self.characters = characters
        self.chunkCount = chunkCount; self.contentHash = contentHash; self.note = note
    }

    var icon: String {
        switch kind {
        case "pdf": "doc.richtext"
        case "image": "photo"
        default: "doc.text"
        }
    }
}

/// One searchable passage of a source.
@Model
final class KnowledgeChunk {
    var id: UUID = UUID()
    var sourceID: UUID = UUID()
    var ordinal: Int = 0
    var text: String = ""
    var locator: String = ""           // "page 3"
    var embedding: Data = Data()       // unit-length Float32 vector; empty when on-device embeddings are unavailable

    init(sourceID: UUID, ordinal: Int, text: String, locator: String, embedding: Data) {
        self.sourceID = sourceID; self.ordinal = ordinal; self.text = text
        self.locator = locator; self.embedding = embedding
    }
}

/// Knowledge lives in its own store that is never synced to iCloud and is left out of device backups.
enum KnowledgeData {
    static let container: ModelContainer = {
        var folder = URL.applicationSupportDirectory.appending(path: "Knowledge", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let schema = Schema([KnowledgeSource.self, KnowledgeChunk.self])
        let configuration = ModelConfiguration("Knowledge", schema: schema, url: folder.appending(path: "knowledge.store"), cloudKitDatabase: .none)
        if let store = try? ModelContainer(for: schema, configurations: configuration) { return store }
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }()

    /// Cheap to read from anywhere (the tool list is built synchronously).
    static let countKey = "knowledge.sources"
    static var hasSources: Bool { UserDefaults.standard.integer(forKey: countKey) > 0 }
    static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.knowledge) as? Bool ?? true }
    static var autoUse: Bool { UserDefaults.standard.object(forKey: Prefs.knowledgeAuto) as? Bool ?? true }
}
