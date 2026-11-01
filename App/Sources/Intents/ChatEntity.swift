import AppIntents
import CoreSpotlight
import SwiftData

/// One SwiftData store shared by the app UI and Siri/Shortcuts intents.
enum AppData {
    /// True when the saved chats couldn't be opened and a temporary empty store is in use instead.
    nonisolated(unsafe) static var isDegraded = false
    static let container: ModelContainer = {
        let schema = Schema([ChatSessionRecord.self, WorkspaceRecord.self, ProviderRecord.self, MCPServerRecord.self, AgentRecord.self,
                             TaskRecord.self, PromptTemplate.self, SSHHostRecord.self, SSHKeyRecord.self, SnippetRecord.self])
        if let store = try? ModelContainer(for: schema) { return store }
        isDegraded = true   // never crash on launch; the saved data is left untouched
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }()
}

/// A saved chat, as Siri, Spotlight and Shortcuts see it.
struct ChatEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat")
    static let defaultQuery = ChatEntityQuery()

    var id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Last message") var preview: String
    @Property(title: "Updated") var updated: Date

    init(_ record: ChatSessionRecord) {
        id = record.id
        title = record.title
        preview = String((record.turns.last { $0.role != .tool }?.text ?? "").prefix(200))
        updated = record.updatedAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: preview.isEmpty ? nil : "\(preview)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = preview
        attributes.contentModificationDate = updated
        return attributes
    }
}

struct ChatEntityQuery: EntityStringQuery {
    @MainActor private func fetch() -> [ChatSessionRecord] {
        let context = AppData.container.mainContext
        let all = (try? context.fetch(FetchDescriptor<ChatSessionRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        return all.filter { !$0.isEmpty }
    }

    @MainActor func entities(for identifiers: [UUID]) async throws -> [ChatEntity] {
        fetch().filter { identifiers.contains($0.id) }.map(ChatEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [ChatEntity] {
        fetch().filter { record in
            record.title.localizedCaseInsensitiveContains(string)
                || record.turns.contains { $0.text.localizedCaseInsensitiveContains(string) }
        }.prefix(25).map(ChatEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [ChatEntity] {
        fetch().prefix(10).map(ChatEntity.init)
    }
}

/// Keeps the Spotlight/Siri index in step with the user's chats. Local to the device;
/// switch it off in Settings and everything is removed from the index.
enum ChatIndexer {
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: Prefs.siriContext) as? Bool ?? true }

    static func update(_ record: ChatSessionRecord) {
        guard isEnabled, !record.isEmpty else { return }
        let entity = ChatEntity(record)
        Task { try? await CSSearchableIndex.default().indexAppEntities([entity]) }
    }

    static func remove(_ id: UUID) {
        Task { try? await CSSearchableIndex.default().deleteAppEntities(identifiedBy: [id], ofType: ChatEntity.self) }
    }

    static func removeAll() {
        Task { try? await CSSearchableIndex.default().deleteAppEntities(ofType: ChatEntity.self) }
    }
}

/// Lets an intent ask the running UI to open something.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    var chatID: UUID?
}
