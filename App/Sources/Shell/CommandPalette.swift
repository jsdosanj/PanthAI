import SwiftData
import SwiftUI

/// ⌘K: jump to any chat or run any command.
struct CommandPalette: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: WindowState
    let records: [ChatSessionRecord]
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let run: () -> Void
    }

    private var items: [Item] {
        var all: [Item] = [
            .init(title: "New Chat", icon: "square.and.pencil") { state.newChat(kind: .chat) },
            .init(title: "New Code Session", icon: "chevron.left.forwardslash.chevron.right") { state.newChat(kind: .code) },
            .init(title: "Toggle Details", icon: "sidebar.trailing") { state.showInspector.toggle() },
            .init(title: "Models", icon: "cpu") { state.selection = .models },
            .init(title: "Hosts", icon: "server.rack") { state.selection = .hosts },
            .init(title: "Pull requests", icon: "arrow.triangle.pull") { state.selection = .pullRequests },
            .init(title: "Compare models", icon: "rectangle.split.2x1") { state.selection = .compare },
            .init(title: "Benchmark", icon: "gauge.with.dots.needle.67percent") { state.selection = .benchmark },
            .init(title: "Fine-tune", icon: "slider.horizontal.3") { state.selection = .finetune },
            .init(title: "Evals", icon: "checklist") { state.selection = .evals },
            .init(title: "Settings", icon: "gearshape") { state.selection = .settings },
        ]
        all += records.filter { !$0.isEmpty }.map { r in
            Item(title: r.title, icon: "bubble.left") { state.open(r.id) }
        }
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats or type a command", text: $query)
                    .focused($focused)
                    .onSubmit { if let first = items.first { first.run(); dismiss() } }
            }
            .font(.title3).padding(16)
            Divider()
            List(items) { item in
                Button { item.run(); dismiss() } label: { Label(item.title, systemImage: item.icon) }
                    .hoverEffect(.highlight)
            }
            .listStyle(.plain)
        }
        .navigationTitle("Search & Commands")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { focused = true }
    }
}
