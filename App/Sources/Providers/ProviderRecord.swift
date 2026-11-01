import Foundation
import SwiftData

enum RemoteKind: String, CaseIterable, Codable, Sendable {
    case openAICompatible, openAIResponses, anthropic

    var label: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible"
        case .openAIResponses: "OpenAI Responses"
        case .anthropic: "Anthropic"
        }
    }
}

/// Ready-made provider setups. LM Studio, Ollama and Osaurus all speak the OpenAI-compatible API.
struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: RemoteKind
    let baseURL: String
    let keyHelp: String
    let needsKey: Bool
    let note: String

    static let all: [ProviderPreset] = [
        .init(id: "anthropic", name: "Claude (Anthropic API)", kind: .anthropic, baseURL: "https://api.anthropic.com",
              keyHelp: "API key from console.anthropic.com", needsKey: true,
              note: "Uses your Anthropic API account (billed per use). A Claude.ai subscription can't be linked by third-party apps."),
        .init(id: "openai", name: "OpenAI (GPT and Codex models)", kind: .openAIResponses, baseURL: "https://api.openai.com/v1",
              keyHelp: "API key from platform.openai.com", needsKey: true,
              note: "Uses your OpenAI API account. Codex models run here through the Responses API. A ChatGPT subscription can't be linked by third-party apps."),
        .init(id: "github", name: "GitHub Models", kind: .openAICompatible, baseURL: "https://models.github.ai/inference",
              keyHelp: "GitHub token with the “models” permission", needsKey: true,
              note: "GitHub's own model API, authenticated with a GitHub token. GitHub Copilot's chat service isn't open to third-party apps."),
        .init(id: "lmstudio", name: "LM Studio", kind: .openAICompatible, baseURL: "http://localhost:1234/v1",
              keyHelp: "Leave empty unless you set a key in LM Studio", needsKey: false,
              note: "On your Mac, start LM Studio's local server and allow network access. Use your Mac's Tailscale name or .local address instead of localhost, e.g. http://my-mac:1234/v1."),
        .init(id: "ollama", name: "Ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1",
              keyHelp: "Leave empty", needsKey: false,
              note: "Replace localhost with your Mac's Tailscale name or .local address."),
        .init(id: "openrouter", name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
              keyHelp: "API key from openrouter.ai", needsKey: true, note: "One key for hundreds of models."),
        .init(id: "custom", name: "Custom (OpenAI-compatible)", kind: .openAICompatible, baseURL: "https://",
              keyHelp: "API key, if the server needs one", needsKey: false, note: "Any server that implements /chat/completions."),
    ]
}

/// A cloud or network model provider. The API key lives in the Keychain, not here.
@Model
final class ProviderRecord {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = RemoteKind.openAICompatible.rawValue
    var baseURL: String = ""
    var modelsData: Data = Data()      // cached model list
    var createdAt: Date = Date.now

    init(name: String, kind: RemoteKind, baseURL: String) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.baseURL = baseURL
    }

    var kind: RemoteKind { RemoteKind(rawValue: kindRaw) ?? .openAICompatible }
    var models: [String] {
        get { (try? JSONDecoder().decode([String].self, from: modelsData)) ?? [] }
        set { modelsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var keyAccount: String { "provider.\(id.uuidString)" }
    var apiKey: String? { Keychain.get(keyAccount) }
    var isLocalNetwork: Bool {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        return host == "localhost" || host.hasSuffix(".local") || !host.contains(".") || host.hasPrefix("100.") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }
}
