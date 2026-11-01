import SwiftData
import SwiftUI

struct AgentPicker: View {
    let model: ChatViewModel
    @Query(sort: \AgentRecord.createdAt) private var agents: [AgentRecord]

    var body: some View {
        if !agents.isEmpty {
            Section("Agent") {
                Picker("Agent", selection: Binding(get: { model.record.agentID }, set: { model.record.agentID = $0 })) {
                    Text("None").tag(UUID?.none)
                    ForEach(agents) { Label($0.name, systemImage: $0.icon).tag(UUID?.some($0.id)) }
                }
            }
        }
    }
}
