import AppIntents
import SwiftData

/// A saved task, as the Shortcuts app lists it.
struct TaskEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task")
    static let defaultQuery = TaskEntityQuery()

    var id: UUID
    @Property(title: "Name") var name: String

    init(_ record: TaskRecord) {
        id = record.id
        name = record.name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TaskEntityQuery: EntityStringQuery {
    @MainActor private func all() -> [TaskRecord] {
        (try? AppData.container.mainContext.fetch(FetchDescriptor<TaskRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }
    @MainActor func entities(for identifiers: [UUID]) async throws -> [TaskEntity] { all().filter { identifiers.contains($0.id) }.map(TaskEntity.init) }
    @MainActor func entities(matching string: String) async throws -> [TaskEntity] { all().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(TaskEntity.init) }
    @MainActor func suggestedEntities() async throws -> [TaskEntity] { all().map(TaskEntity.init) }
}

/// Run a saved task. Put it in a Shortcuts automation (time of day, arriving somewhere, charging…)
/// to schedule it. The result is saved as a chat and returned to the shortcut.
struct RunTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run DosanjhAI Task"
    static let description = IntentDescription("Runs one of your saved DosanjhAI tasks and returns the result. Use it in a Shortcuts automation to schedule it.")
    static let openAppWhenRun = false

    @Parameter(title: "Task") var task: TaskEntity
    @Parameter(title: "Extra input", description: "Optional text added to the task's prompt, such as the output of another action.")
    var extraInput: String?

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$task) with \(\.$extraInput)") }

    enum TaskError: Error, CustomLocalizedStringResourceConvertible {
        case missing, localModelInBackground, unavailable
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .missing: "That task no longer exists."
            case .localModelInBackground: "Downloaded models can't run in the background. Pick Apple's on-device model, a cloud model or LM Studio for this task."
            case .unavailable: "That model isn't available right now."
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let context = AppData.container.mainContext
        guard let task = (try? context.fetch(FetchDescriptor<TaskRecord>()))?.first(where: { $0.id == self.task.id }) else { throw TaskError.missing }
        if case .mlx = task.choice, !Notifier.appIsActive { throw TaskError.localModelInBackground }

        let record = ChatSessionRecord(providerKey: task.providerKey, kind: task.kind)
        record.title = "\(task.name) · \(Date.now.formatted(date: .abbreviated, time: .shortened))"
        record.agentIDString = task.agentIDString
        record.network = task.network
        context.insert(record)
        let model = ChatViewModel(record: record) { try? context.save() }
        guard model.status == .available else { throw TaskError.unavailable }
        if let id = UUID(uuidString: task.workspaceIDString) {
            model.attach((try? context.fetch(FetchDescriptor<WorkspaceRecord>()))?.first { $0.id == id })
            record.workspaceID = id
        }
        if extraInput != nil { record.tainted = true }   // text from other Shortcut actions is untrusted
        model.mode = task.allowEdits ? .autoEdit : .ask
        await model.runHeadless(extraInput.map { task.prompt + "\n\n" + $0 } ?? task.prompt)

        let reply = ToolProtocol.stripCall(from: model.turns.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text ?? "")
        task.lastRun = .now
        task.lastResult = String(reply.prefix(2_000))
        try? context.save()
        ChatIndexer.update(record)
        Notifier.post(.reply, title: task.name, body: reply.isEmpty ? "Finished." : reply, chatID: record.id)
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply.isEmpty ? "Done." : String(reply.prefix(300))))
    }
}
