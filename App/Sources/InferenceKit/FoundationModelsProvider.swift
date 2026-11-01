import Foundation
import FoundationModels

enum AppleModelKind: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    /// Apple's larger model, run on Apple's Private Cloud Compute (iPadOS 27+).
    case privateCloud

    var id: String { rawValue }
    var title: String {
        switch self {
        case .onDevice: "Apple on-device"
        case .privateCloud: "Apple advanced (Private Cloud)"
        }
    }
}

enum AppleIntelligenceStatus: Sendable, Equatable {
    case available
    case unavailable(String)

    static func current(_ kind: AppleModelKind = .onDevice) -> AppleIntelligenceStatus {
        switch kind {
        case .onDevice:
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unavailable("This iPad doesn't support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Turn on Apple Intelligence in Settings.")
            case .unavailable(.modelNotReady): return .unavailable("The on-device model is still downloading.")
            case .unavailable: return .unavailable("Apple's on-device model isn't available right now.")
            }
        case .privateCloud:
            guard #available(iOS 27.0, *) else {
                return .unavailable("The advanced Apple model needs iPadOS 27 or later.")
            }
            switch PrivateCloudComputeLanguageModel().availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unavailable("This iPad can't use Private Cloud Compute.")
            case .unavailable(.systemNotReady): return .unavailable("Apple's advanced model isn't ready yet. Try again shortly.")
            @unknown default: return .unavailable("Apple's advanced model isn't available right now.")
            }
        }
    }
}

struct FoundationModelsProvider: ModelProvider {
    let kind: AppleModelKind
    var displayName: String { kind.title }

    init(kind: AppleModelKind = .onDevice) { self.kind = kind }

    private func makeSession(instructions: String) -> LanguageModelSession {
        if kind == .privateCloud, #available(iOS 27.0, *) {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
        }
        return LanguageModelSession(instructions: instructions)
    }

    func stream(prompt: String, history: [ChatTurn], kind sessionKind: SessionKind, extraInstructions: String, sampling: SamplingSettings) -> AsyncThrowingStream<String, Error> {
        let personalization = Personalization.load()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transcript = ContextBudget.trim(history, maxChars: ContextBudget.appleChars).map { "\($0.role.rawValue): \($0.modelText)" }.joined(separator: "\n")
                    let session = makeSession(instructions: personalization.instructions(conversation: transcript, kind: sessionKind, extra: extraInstructions))
                    var options = GenerationOptions(temperature: sampling.temperature ?? personalization.temperature, maximumResponseTokens: sampling.maxTokens)
                    if sampling.temperature == 0 { options.sampling = .greedy }
                    else if let k = sampling.topK, k > 0 { options.sampling = .random(top: k, seed: sampling.seed.map(UInt64.init)) }
                    else if let p = sampling.topP { options.sampling = .random(probabilityThreshold: p, seed: sampling.seed.map(UInt64.init)) }
                    for try await partial in session.streamResponse(to: prompt, options: options) {
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
