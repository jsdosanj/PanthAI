import Foundation
import SwiftData

/// One saved conversation. Every property has a default and nothing is unique,
/// so the model is CloudKit-compatible for the iCloud sync phase.
@Model
final class ChatSessionRecord {
    var id: UUID = UUID()
    var title: String = "New Chat"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var providerKey: String = ProviderChoice.apple(.onDevice).key
    var turnsData: Data = Data()
    var kindRaw: String = SessionKind.chat.rawValue
    var workspaceIDString: String = ""
    var pinnedData: Data = Data()
    var modeRaw: String = PermissionMode.ask.rawValue
    var networkRaw: String = NetworkMode.full.rawValue
    var networkHostsData: Data = Data()
    var agentIDString: String = ""
    var mcpData: Data = Data()
    var samplingData: Data = Data()
    var schemaText: String = ""
    var parentIDString: String = ""
    var sshHostIDString: String = ""
    /// This chat has read web, connector or remote-machine content (or a public repo), so approvals can no longer be waived.
    var tainted: Bool = false

    init(providerKey: String = ProviderChoice.apple(.onDevice).key, kind: SessionKind = .chat) {
        self.providerKey = providerKey
        self.kindRaw = kind.rawValue
        self.networkRaw = NetworkMode(rawValue: UserDefaults.standard.string(forKey: Prefs.defaultNetwork) ?? "") .map(\.rawValue) ?? NetworkMode.full.rawValue
    }

    var kind: SessionKind { SessionKind(rawValue: kindRaw) ?? .chat }
    var mode: PermissionMode {
        get { PermissionMode(rawValue: modeRaw) ?? .ask }
        set { modeRaw = newValue.rawValue }
    }
    var sampling: SamplingSettings {
        get { (try? JSONDecoder().decode(SamplingSettings.self, from: samplingData)) ?? SamplingSettings() }
        set { samplingData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var sshHostID: UUID? {
        get { UUID(uuidString: sshHostIDString) }
        set { sshHostIDString = newValue?.uuidString ?? "" }
    }
    var parentID: UUID? {
        get { UUID(uuidString: parentIDString) }
        set { parentIDString = newValue?.uuidString ?? "" }
    }
    var enabledConnectors: [UUID] {
        get { ((try? JSONDecoder().decode([String].self, from: mcpData)) ?? []).compactMap(UUID.init) }
        set { mcpData = (try? JSONEncoder().encode(newValue.map(\.uuidString))) ?? Data() }
    }
    var allowedHosts: [String] {
        get { (try? JSONDecoder().decode([String].self, from: networkHostsData)) ?? [] }
        set { networkHostsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var agentID: UUID? {
        get { UUID(uuidString: agentIDString) }
        set { agentIDString = newValue?.uuidString ?? "" }
    }
    var network: NetworkMode {
        get { NetworkMode(rawValue: networkRaw) ?? .full }
        set { networkRaw = newValue.rawValue }
    }
    var workspaceID: UUID? {
        get { UUID(uuidString: workspaceIDString) }
        set { workspaceIDString = newValue?.uuidString ?? "" }
    }
    var pinnedPaths: [String] {
        get { (try? JSONDecoder().decode([String].self, from: pinnedData)) ?? [] }
        set { pinnedData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var turns: [ChatTurn] {
        get { (try? JSONDecoder().decode([ChatTurn].self, from: turnsData)) ?? [] }
        set { turnsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var isEmpty: Bool { turnsData.isEmpty || turns.isEmpty }
}

/// Which engine answers a chat. Stored as a string so sessions survive model changes.
enum ProviderChoice: Hashable, Sendable {
    case apple(AppleModelKind)
    case mlx(String)
    /// A model on a cloud or network provider: provider id and model name.
    case remote(UUID, String)
    /// Claude Code or Codex running on one of the user's own machines over SSH: host id and agent ("claude" / "codex").
    case ssh(UUID, String)

    var key: String {
        switch self {
        case .apple(let kind): "apple.\(kind.rawValue)"
        case .mlx(let repo): "mlx.\(repo)"
        case .remote(let id, let model): "remote.\(id.uuidString)|\(model)"
        case .ssh(let id, let agent): "ssh.\(id.uuidString)|\(agent)"
        }
    }

    init(key: String) {
        if key.hasPrefix("ssh."), let bar = key.firstIndex(of: "|"),
           let id = UUID(uuidString: String(key[key.index(key.startIndex, offsetBy: 4)..<bar])) {
            self = .ssh(id, String(key[key.index(after: bar)...]))
        }
        else if key.hasPrefix("remote."), let bar = key.firstIndex(of: "|"),
           let id = UUID(uuidString: String(key[key.index(key.startIndex, offsetBy: 7)..<bar])) {
            self = .remote(id, String(key[key.index(after: bar)...]))
        }
        else if key.hasPrefix("mlx.") { self = .mlx(String(key.dropFirst(4))) }
        else if let kind = AppleModelKind(rawValue: String(key.dropFirst("apple.".count))) { self = .apple(kind) }
        else { self = .apple(.onDevice) }
    }

    private static let lastKey = "session.lastProvider"
    static var lastUsed: ProviderChoice {
        ProviderChoice(key: UserDefaults.standard.string(forKey: lastKey) ?? ProviderChoice.apple(.onDevice).key)
    }
    func remember() { UserDefaults.standard.set(key, forKey: Self.lastKey) }

    var label: String {
        switch self {
        case .apple(let kind): kind.title
        case .mlx(let repo): CuratedModels.everything.first { $0.id == repo }?.name ?? repo
        case .remote(_, let model): model
        case .ssh(_, let agent): (RemoteAgentKind(rawValue: agent) ?? .claude).title + " (remote)"
        }
    }
}

/// A regular chat, or a code session meant for long, tool-heavy work.
enum SessionKind: String, Sendable, CaseIterable, Identifiable {
    case chat, code
    var id: String { rawValue }
    var label: String { self == .chat ? "Chats" : "Code" }
    var newLabel: String { self == .chat ? "New Chat" : "New Code Session" }
    var icon: String { self == .chat ? "bubble.left" : "chevron.left.forwardslash.chevron.right" }
}

/// Claude Code-style modes, cycled with Shift-Tab.
enum PermissionMode: String, CaseIterable, Sendable {
    case ask, autoEdit, plan
    var label: String {
        switch self {
        case .ask: "Ask before edits"
        case .autoEdit: "Auto-accept edits"
        case .plan: "Plan mode"
        }
    }
    var icon: String {
        switch self {
        case .ask: "hand.raised"
        case .autoEdit: "bolt"
        case .plan: "list.bullet.clipboard"
        }
    }
    var next: PermissionMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// First-use consent before a chat is sent to a cloud or network provider (App Review 5.1.2(i) and plain honesty).
enum CloudConsent {
    private static let key = "consent.cloud"
    static func accepted(_ id: UUID) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id.uuidString) }
    static func accept(_ id: UUID) {
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !all.contains(id.uuidString) { all.append(id.uuidString) }
        UserDefaults.standard.set(all, forKey: key)
    }
}
