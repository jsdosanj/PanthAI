import AppIntents
import FoundationModels
import SwiftData

/// "Ask PanthAI …" from Siri, Spotlight, Shortcuts and the Action button.
/// Runs on-device and never opens the app. Pass a chat to continue it with its full context.
struct AskIpadAIIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Ask PanthAI"
    static let description = IntentDescription("Ask the on-device model a question, optionally inside one of your chats.")
    static let openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    @Parameter(title: "Chat", description: "Continue this chat so the answer uses its context.")
    var chat: ChatEntity?

    static var parameterSummary: some ParameterSummary { Summary("Ask PanthAI \(\.$question) in \(\.$chat)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard case .available = AppleIntelligenceStatus.current(.onDevice) else { throw IntentError.unavailable }
        let context = AppData.container.mainContext
        let record = chat.flatMap { entity in
            (try? context.fetch(FetchDescriptor<ChatSessionRecord>()))?.first { $0.id == entity.id }
        }
        let history = ContextBudget.trim(record?.turns ?? [], maxChars: ContextBudget.appleChars)
        let transcript = history.map { "\($0.role.rawValue): \($0.modelText)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: Personalization.load().instructions(conversation: transcript, kind: record?.kind ?? .chat))
        let reply = try await session.respond(to: question).content

        if let record {   // keep the exchange in the chat so the app shows it too
            if let live = ChatRegistry.model(record.id) {
                live.appendExchange(question: question, reply: reply)   // the open chat owns its turns; writing the record would be overwritten by its next save
            } else {
                record.turns += [ChatTurn(role: .user, text: question), ChatTurn(role: .assistant, text: reply)]
                record.updatedAt = .now
                try? context.save()
                ChatIndexer.update(record)
            }
        }
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case unavailable
        var localizedStringResource: LocalizedStringResource { "Apple Intelligence isn't available on this iPad right now." }
    }
}

struct OpenChatIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Open one of your PanthAI chats.")
    static let openAppWhenRun = true

    @Parameter(title: "Chat") var chat: ChatEntity

    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.chatID = chat.id
        return .result()
    }
}

struct GetLastReplyIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Get Last Reply"
    static let description = IntentDescription("Returns the most recent reply in a chat so you can use it in an automation.")
    static let openAppWhenRun = false

    @Parameter(title: "Chat") var chat: ChatEntity

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let records = (try? AppData.container.mainContext.fetch(FetchDescriptor<ChatSessionRecord>())) ?? []
        let reply = records.first { $0.id == chat.id }?.turns.last { $0.role == .assistant && $0.text.isEmpty == false }?.text ?? ""
        return .result(value: reply)
    }
}

struct SearchChatsIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Search Chats"
    static let description = IntentDescription("Find PanthAI chats that mention something.")
    static let openAppWhenRun = false

    @Parameter(title: "Search for") var text: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ChatEntity]> {
        .result(value: try await ChatEntityQuery().entities(matching: text))
    }
}

struct IpadAIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskIpadAIIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question", "Chat with \(.applicationName)"],
                    shortTitle: "Ask PanthAI", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: RunTaskIntent(),
                    phrases: ["Run \(\.$task) in \(.applicationName)"],
                    shortTitle: "Run Task", systemImageName: "clock.arrow.circlepath")
        AppShortcut(intent: OpenChatIntent(),
                    phrases: ["Open \(\.$chat) in \(.applicationName)"],
                    shortTitle: "Open Chat", systemImageName: "bubble.left")
        AppShortcut(intent: GetLastReplyIntent(),
                    phrases: ["Get the last reply from \(\.$chat) in \(.applicationName)"],
                    shortTitle: "Get Last Reply", systemImageName: "text.bubble")
    }
}
