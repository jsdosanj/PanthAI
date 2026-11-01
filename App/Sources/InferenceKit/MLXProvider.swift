import Foundation
import MLXLMCommon

/// Wraps one `ChatSession`, which keeps its own KV cache so only the new
/// prompt is processed each turn. If the saved conversation no longer matches
/// the session (reopened chat, regenerate, model swap) the session is rebuilt
/// from the stored history.
final class MLXProvider: ModelProvider, @unchecked Sendable {
    let displayName: String
    private let container: ModelContainer
    private let lock = NSLock()

    private func setKnownTurns(_ value: Int) { lock.withLock { knownTurns = value } }
    private var session: ChatSession?
    private var knownTurns = -1

    init(name: String, container: ModelContainer) {
        displayName = name
        self.container = container
    }

    private func session(for history: [ChatTurn], kind: SessionKind, extra: String) -> ChatSession {
        lock.withLock { buildSession(history: history, kind: kind, extra: extra) }
    }

    private func buildSession(history: [ChatTurn], kind: SessionKind, extra: String) -> ChatSession {
        let instructions = Personalization.load().instructions(kind: kind, extra: extra)
        let trimmed = ContextBudget.trim(history, maxChars: ContextBudget.mlxChars)
        if let session, knownTurns == history.count {
            session.instructions = instructions
            return session
        }
        let messages: [Chat.Message] = [.system(instructions)] + trimmed.map {
            $0.role == .assistant ? .assistant($0.modelText) : .user($0.modelText)
        }
        let rebuilt = ChatSession(container, history: messages)
        session = rebuilt
        return rebuilt
    }

    func stream(prompt: String, history: [ChatTurn], kind: SessionKind, extraInstructions: String, sampling: SamplingSettings) -> AsyncThrowingStream<String, Error> {
        // ChatSession isn't Sendable; this provider serialises access (one generation at a time per chat).
        let chat = session(for: history, kind: kind, extra: extraInstructions)
        var parameters = GenerateParameters()
        if let v = sampling.temperature { parameters.temperature = Float(v) }
        if let v = sampling.topP { parameters.topP = Float(v) }
        if let v = sampling.topK { parameters.topK = v }
        if let v = sampling.minP { parameters.minP = Float(v) }
        if let v = sampling.repeatPenalty { parameters.repetitionPenalty = Float(v) }
        if let v = sampling.seed { parameters.seed = UInt64(v) }
        if let v = sampling.maxTokens { parameters.maxTokens = v }
        chat.generateParameters = parameters
        let box = SessionBox(session: chat)
        let expected = history.count + 2
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var text = ""
                    for try await chunk in box.session.streamResponse(to: prompt) {
                        text += chunk
                        continuation.yield(text)
                    }
                    setKnownTurns(expected)
                    continuation.finish()
                } catch {
                    setKnownTurns(-1)   // cancelled/failed: rebuild next time
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct SessionBox: @unchecked Sendable { let session: ChatSession }
