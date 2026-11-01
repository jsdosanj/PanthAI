import Foundation
import SwiftData

/// A named assistant with its own instructions, memory and favourite model.
@Model
final class AgentRecord {
    var id: UUID = UUID()
    var name: String = ""
    var icon: String = "sparkles"
    var instructions: String = ""
    /// Empty means "use whatever model I used last".
    var providerKey: String = ""
    var createdAt: Date = Date.now

    init(name: String, icon: String = "sparkles", instructions: String = "") {
        self.name = name
        self.icon = icon
        self.instructions = instructions
    }

    /// What gets added to the model's instructions for chats with this agent.
    var promptBlock: String {
        var parts = ["You are acting as the assistant named \"\(name)\"."]
        if !instructions.isEmpty { parts.append(instructions) }
        let notes = MemoryStore.load(agent: id)
        if !notes.isEmpty { parts.append("Your own notes from earlier work:\n" + String(notes.suffix(2_000))) }
        return parts.joined(separator: "\n")
    }
}
