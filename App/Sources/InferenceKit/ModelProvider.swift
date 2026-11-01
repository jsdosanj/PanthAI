import Foundation

struct ChatTurn: Sendable, Identifiable, Equatable {
    enum Role: String, Sendable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// One interface over Apple Foundation Models, MLX and remote providers.
protocol ModelProvider: Sendable {
    var displayName: String { get }
    /// Streams the *cumulative* reply text so the UI can just replace it.
    func stream(prompt: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}
