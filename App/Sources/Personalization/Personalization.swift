import Foundation

/// UserDefaults keys shared by Settings, chat and the Siri intents.
enum Prefs {
    static let displayName = "pers.displayName"
    static let about = "pers.about"
    static let style = "pers.style"
    static let extra = "pers.extra"
    static let useTemperature = "pers.useTemperature"
    static let temperature = "pers.temperature"
    static let returnSends = "kb.returnSends"
    static let focusOnLaunch = "kb.focusOnLaunch"
    static let siriContext = "siri.context"
    static let webSearch = "tools.webSearch"
    static let codeExecution = "tools.codeExecution"
    static let memory = "tools.memory"
    static let defaultNetwork = "net.default"
    static let appLock = "sec.appLock"
    static let lockGrace = "sec.lockGrace"
    static let hideInSwitcher = "sec.hideInSwitcher"
    static let protectKeys = "sec.protectKeys"
    static let maxProtection = "sec.maxProtection"
    static let offline = "net.offline"
    static let offlineAllowLocal = "net.offlineAllowLocal"
}

enum ResponseStyle: String, CaseIterable, Identifiable, Sendable {
    case balanced, concise, detailed, friendly, formal
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var directive: String {
        switch self {
        case .balanced: "Answer clearly with a sensible level of detail."
        case .concise: "Be brief. Lead with the answer and skip filler."
        case .detailed: "Explain thoroughly, with steps and examples where useful."
        case .friendly: "Use a warm, conversational tone."
        case .formal: "Use a precise, professional tone."
        }
    }
}

/// A snapshot of the user's personalization, turned into model instructions.
/// Stays on the device (and, later, syncs through the user's own iCloud).
struct Personalization: Sendable, Equatable {
    var displayName = ""
    var about = ""
    var style: ResponseStyle = .balanced
    var extraInstructions = ""
    var temperature: Double?
    var agentID: UUID?

    static func load(_ defaults: UserDefaults = .standard) -> Personalization {
        Personalization(
            displayName: defaults.string(forKey: Prefs.displayName) ?? "",
            about: defaults.string(forKey: Prefs.about) ?? "",
            style: ResponseStyle(rawValue: defaults.string(forKey: Prefs.style) ?? "") ?? .balanced,
            extraInstructions: defaults.string(forKey: Prefs.extra) ?? "",
            temperature: defaults.bool(forKey: Prefs.useTemperature) ? defaults.double(forKey: Prefs.temperature) : nil)
    }

    func instructions(conversation: String = "", kind: SessionKind = .chat, extra: String = "") -> String {
        var parts = ["You are PanthAI, a helpful assistant running on the user's iPad.", style.directive]
        if kind == .code {
            parts.append("This is a long-running coding session. Write complete, correct code in fenced blocks with a language tag. Keep answers focused, remember files, names and decisions from earlier in the session, and say so when you are unsure rather than guessing.")
        }
        if !displayName.isEmpty { parts.append("The user's name is \(displayName).") }
        if !about.isEmpty { parts.append("About the user: \(about)") }
        if !extraInstructions.isEmpty { parts.append(extraInstructions) }
        if !extra.isEmpty { parts.append(extra) }
        if UserDefaults.standard.object(forKey: Prefs.memory) as? Bool ?? true {
            let memory = MemoryStore.promptBlock(agent: agentID)
            if !memory.isEmpty { parts.append(memory) }
        }
        if !conversation.isEmpty { parts.append("Conversation so far:\n\(conversation)") }
        return parts.joined(separator: "\n")
    }
}
