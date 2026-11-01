import SwiftData
import SwiftUI

struct AgentsSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AgentRecord.createdAt) private var agents: [AgentRecord]

    var body: some View {
        Section {
            ForEach(agents) { agent in
                NavigationLink { AgentEditor(agent: agent) } label: { Label(agent.name, systemImage: agent.icon) }
            }
            .onDelete { offsets in
                for i in offsets { MemoryStore.save("", agent: agents[i].id); context.delete(agents[i]) }
                try? context.save()
            }
            Button("New agent…", systemImage: "plus") {
                let agent = AgentRecord(name: "New agent")
                context.insert(agent)
                try? context.save()
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("An agent is a named assistant with its own instructions and memory, such as a Swift reviewer or a translator. Start a chat with one from the New Chat button.")
        }
    }
}

struct AgentEditor: View {
    @Bindable var agent: AgentRecord
    @State private var notes = ""
    private let icons = ["sparkles", "chevron.left.forwardslash.chevron.right", "character.bubble", "paintpalette", "doc.text", "graduationcap", "hammer", "globe", "brain"]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $agent.name)
                Picker("Icon", selection: $agent.icon) { ForEach(icons, id: \.self) { Label($0, systemImage: $0).tag($0) } }
                TextField("Instructions — what this agent is for and how it should act", text: $agent.instructions, axis: .vertical).lineLimit(4...12)
            }
            Section {
                Picker("Model", selection: $agent.providerKey) {
                    Text("Last used").tag("")
                    Text(ProviderChoice.apple(.onDevice).label).tag(ProviderChoice.apple(.onDevice).key)
                    ForEach(CuratedModels.everything.filter { ModelManager.shared.isDownloaded($0.id) }) { Text($0.name).tag(ProviderChoice.mlx($0.id).key) }
                }
            }
            Section {
                TextEditor(text: $notes).frame(minHeight: 160).font(.body.monospaced())
                    .onChange(of: notes) { _, new in MemoryStore.save(new, agent: agent.id) }
            } header: { Text("This agent's memory") } footer: {
                Text("Saved by the agent with the remember tool, or written by you. Stays on this iPad.")
            }
        }
        .navigationTitle(agent.name)
        .onAppear { notes = MemoryStore.load(agent: agent.id) }
    }
}
