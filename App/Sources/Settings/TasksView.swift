import AppIntents
import SwiftData
import SwiftUI

struct TasksSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskRecord.createdAt) private var tasks: [TaskRecord]

    var body: some View {
        Section {
            ForEach(tasks) { task in
                NavigationLink { TaskEditor(task: task) } label: {
                    VStack(alignment: .leading) {
                        Text(task.name)
                        Text(task.lastRun.map { "Last run \($0.formatted(.relative(presentation: .named)))" } ?? "Never run")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in for i in offsets { context.delete(tasks[i]) }; try? context.save() }
            Button("New task…", systemImage: "plus") {
                context.insert(TaskRecord(name: "New task", prompt: "Summarise the most important news about ")); try? context.save()
            }
            ShortcutsLink()
        } header: {
            Text("Scheduled tasks")
        } footer: {
            Text("To run a task on a schedule: open Shortcuts → Automation → New Automation → pick a time (or a place, or when charging) → add the “Run DosanjhAI Task” action → choose your task. iPadOS decides how long background actions may run, so keep tasks short. Downloaded models can't run in the background; use Apple's model, a cloud model or LM Studio.")
        }
    }
}

struct TaskEditor: View {
    @Bindable var task: TaskRecord
    @Query(sort: \AgentRecord.createdAt) private var agents: [AgentRecord]
    @Query(sort: \WorkspaceRecord.importedAt) private var repos: [WorkspaceRecord]
    @Query(sort: \ProviderRecord.createdAt) private var providers: [ProviderRecord]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $task.name)
                TextField("What should it do?", text: $task.prompt, axis: .vertical).lineLimit(3...10)
                Picker("Type", selection: $task.kindRaw) { ForEach(SessionKind.allCases) { Text($0.label).tag($0.rawValue) } }
            }
            Section("Model") {
                Picker("Model", selection: $task.providerKey) {
                    ForEach(AppleModelKind.allCases) { Text($0.title).tag(ProviderChoice.apple($0).key) }
                    ForEach(providers) { provider in
                        ForEach(provider.models.prefix(30), id: \.self) { Text("\(provider.name): \($0)").tag(ProviderChoice.remote(provider.id, $0).key) }
                    }
                }
            }
            Section("Context") {
                Picker("Agent", selection: $task.agentIDString) {
                    Text("None").tag("")
                    ForEach(agents) { Text($0.name).tag($0.id.uuidString) }
                }
                Picker("Repo", selection: $task.workspaceIDString) {
                    Text("None").tag("")
                    ForEach(repos) { Text($0.displayName).tag($0.id.uuidString) }
                }
                Picker("Network", selection: $task.networkRaw) { ForEach(NetworkMode.allCases) { Text($0.label).tag($0.rawValue) } }
            }
            Section {
                Toggle("Allow file edits without asking", isOn: $task.allowEdits)
            } footer: {
                Text("Nobody is there to tap Allow when a task runs on a schedule, so anything that needs approval is skipped: pushing code, connectors and sending data. Reading, searching the web and (if you allow it) editing files still work.")
            }
            if !task.lastResult.isEmpty {
                Section("Last result") { Text(task.lastResult).font(.callout).textSelection(.enabled) }
            }
        }
        .navigationTitle(task.name)
    }
}
