import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Bindable var state: WindowState
    let records: [ChatSessionRecord]
    @State private var pendingDelete: ChatSessionRecord?
    @Query(sort: \AgentRecord.createdAt) private var agents: [AgentRecord]

    private var filtered: [ChatSessionRecord] {
        let nonEmpty = records.filter { $0.kind == state.sidebarKind && (!$0.isEmpty || state.openTabs.contains($0.id)) }
        guard !state.searchText.isEmpty else { return nonEmpty }
        return nonEmpty.filter {
            $0.title.localizedCaseInsensitiveContains(state.searchText)
                || $0.turns.contains { $0.text.localizedCaseInsensitiveContains(state.searchText) }
        }
    }

    private var groups: [(title: String, items: [ChatSessionRecord])] {
        let cal = Calendar.current
        let buckets: [(String, (Date) -> Bool)] = [
            ("Today", { cal.isDateInToday($0) }),
            ("Yesterday", { cal.isDateInYesterday($0) }),
            ("Previous 7 Days", { $0 > cal.date(byAdding: .day, value: -7, to: .now)! }),
            ("Older", { _ in true }),
        ]
        var remaining = filtered
        var result: [(String, [ChatSessionRecord])] = []
        for (title, test) in buckets {
            let hit = remaining.filter { test($0.updatedAt) }
            remaining.removeAll { r in hit.contains { $0.id == r.id } }
            if !hit.isEmpty { result.append((title, hit)) }
        }
        return result
    }

    var body: some View {
        List(selection: $state.selection) {
            Section {
                Picker("Type", selection: $state.sidebarKind) {
                    ForEach(SessionKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                Menu {
                    ForEach(agents) { agent in
                        Button(agent.name, systemImage: agent.icon) { state.newChat(in: context, kind: state.sidebarKind, agent: agent) }
                    }
                } label: {
                    Label(state.sidebarKind.newLabel, systemImage: "square.and.pencil")
                } primaryAction: {
                    state.newChat(in: context, kind: state.sidebarKind)
                }
                Button { state.showPalette = true } label: {
                    Label("Commands", systemImage: "command")
                }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { record in
                        row(record).tag(SidebarItem.chat(record.id))
                    }
                }
            }
            Section("Lab") {
                Label("Compare models", systemImage: "rectangle.split.2x1").tag(SidebarItem.compare)
                Label("Benchmark", systemImage: "gauge.with.dots.needle.67percent").tag(SidebarItem.benchmark)
                Label("Evals", systemImage: "checklist").tag(SidebarItem.evals)
                Label("Fine-tune", systemImage: "slider.horizontal.3").tag(SidebarItem.finetune)
            }
            Section("Library") {
                Label("Models", systemImage: "cpu").tag(SidebarItem.models)
                Label("Hosts", systemImage: "server.rack").tag(SidebarItem.hosts)
                Label("Pull requests", systemImage: "arrow.triangle.pull").tag(SidebarItem.pullRequests)
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search chats")
        .navigationTitle("PanthAI")
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { record in
            Button("Delete Chat", role: .destructive) {
                state.forget(record.id)
                ChatIndexer.remove(record.id)
                context.delete(record)
                try? context.save()
            }
        } message: { _ in Text("This can't be undone.") }
        .onChange(of: state.selection) { _, new in
            if case .chat(let id) = new, !state.openTabs.contains(id) { state.openTabs.append(id) }
            if case .chat(let id) = new, let kind = records.first(where: { $0.id == id })?.kind { state.sidebarKind = kind }
        }
    }

    private func row(_ record: ChatSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(record.title, systemImage: agents.first { $0.id == record.agentID }?.icon ?? record.kind.icon).lineLimit(1)
            Text(ProviderChoice(key: record.providerKey).label)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .hoverEffect(.highlight)
        .contextMenu {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(id: "chat", value: record.id) }
            Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = record }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { pendingDelete = record }
        }
    }
}
