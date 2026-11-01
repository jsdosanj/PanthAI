import Foundation

enum ToolStatus: String, Sendable, Codable { case pending, running, done, denied, failed, undone }

struct ChatTurn: Sendable, Identifiable, Equatable, Codable {
    enum Role: String, Sendable, Codable { case user, assistant, tool }
    var id = UUID()
    let role: Role
    var text: String
    // Tool turns: the call, its state, and any file change (for diffs and undo).
    var toolName: String?
    var toolArgs: String?
    var toolStatus: ToolStatus?
    var changeScope: String?
    var changePath: String?
    var changeBefore: String?
    var changeAfter: String?
    /// A `/compact` summary standing in for older messages.
    var isSummary: Bool?

    /// How this turn is shown to the model.
    var modelText: String {
        switch role {
        case .tool: "Tool result (\(toolName ?? "tool")):\n\(text)"
        default: isSummary == true ? "Summary of the earlier conversation:\n\(text)" : text
        }
    }
}

/// One interface over Apple Foundation Models, MLX and remote providers.
protocol ModelProvider: Sendable {
    var displayName: String { get }
    /// Streams the *cumulative* reply text so the UI can just replace it.
    func stream(prompt: String, history: [ChatTurn], kind: SessionKind, extraInstructions: String, sampling: SamplingSettings) -> AsyncThrowingStream<String, Error>
}

/// Keeps long conversations inside the model's context window by dropping the
/// oldest turns first. PROVISIONAL character budgets (~4 chars per token);
/// tune after on-device measurement.
enum ContextBudget {
    static let appleChars = 8_000       // on-device Apple model has a ~4k-token window
    static let mlxChars = 40_000

    static func trim(_ history: [ChatTurn], maxChars: Int) -> [ChatTurn] {
        var total = 0
        var kept: [ChatTurn] = []
        for turn in history.reversed() {
            total += turn.modelText.count
            if total > maxChars { break }
            kept.append(turn)
        }
        return kept.reversed()
    }

    static func estimatedTokens(_ turns: [ChatTurn]) -> Int { turns.reduce(0) { $0 + $1.text.count } / 4 }
}
