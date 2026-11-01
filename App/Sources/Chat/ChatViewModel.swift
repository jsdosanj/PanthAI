import Foundation
import Observation

@MainActor @Observable
final class ChatViewModel {
    var turns: [ChatTurn] = []
    var input = ""
    var isStreaming = false
    var errorMessage: String?

    private let provider: any ModelProvider
    private var streamTask: Task<Void, Never>?

    init(provider: any ModelProvider = FoundationModelsProvider()) { self.provider = provider }

    var providerName: String { provider.displayName }

    func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }
        input = ""
        errorMessage = nil
        let history = turns
        turns.append(.init(role: .user, text: prompt))
        turns.append(.init(role: .assistant, text: ""))
        let index = turns.count - 1
        isStreaming = true
        streamTask = Task {
            do {
                for try await text in provider.stream(prompt: prompt, history: history) {
                    turns[index].text = text
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isStreaming = false
        }
    }

    func stop() { streamTask?.cancel() }
}
