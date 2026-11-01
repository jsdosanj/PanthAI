import Foundation
import FoundationModels

enum AppleIntelligenceStatus: Sendable, Equatable {
    case available
    case unavailable(String)

    static var current: AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .unavailable("This iPad doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled): .unavailable("Turn on Apple Intelligence in Settings.")
        case .unavailable(.modelNotReady): .unavailable("The on-device model is still downloading.")
        case .unavailable: .unavailable("Apple's on-device model isn't available right now.")
        }
    }
}

struct FoundationModelsProvider: ModelProvider {
    let displayName = "Apple Foundation Model"

    func stream(prompt: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transcript = history.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
                    let session = LanguageModelSession(instructions: "You are ipadAI, a concise, helpful assistant. Prior conversation:\n\(transcript)")
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
