import Foundation
import SwiftData

/// A saved prompt that Shortcuts can run on a schedule or trigger ("Run PanthAI Task").
@Model
final class TaskRecord {
    var id: UUID = UUID()
    var name: String = ""
    var prompt: String = ""
    var kindRaw: String = SessionKind.chat.rawValue
    var agentIDString: String = ""
    var workspaceIDString: String = ""
    var providerKey: String = ProviderChoice.apple(.onDevice).key
    var networkRaw: String = NetworkMode.full.rawValue
    /// Lets the task edit files in its repo and create files without a person there to approve.
    var allowEdits: Bool = false
    var lastRun: Date?
    var lastResult: String = ""
    var createdAt: Date = Date.now

    init(name: String, prompt: String = "") {
        self.name = name
        self.prompt = prompt
    }

    var kind: SessionKind { SessionKind(rawValue: kindRaw) ?? .chat }
    var network: NetworkMode { NetworkMode(rawValue: networkRaw) ?? .full }
    var choice: ProviderChoice { ProviderChoice(key: providerKey) }
}
