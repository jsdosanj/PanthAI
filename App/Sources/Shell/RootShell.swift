import SwiftData
import SwiftUI

/// The desktop-style window: sidebar, tabbed content, optional inspector.
struct RootShell: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatSessionRecord.updatedAt, order: .reverse) private var records: [ChatSessionRecord]
    @State private var state = WindowState()

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            SidebarView(state: state, records: records)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.windowState, state)
        .safeAreaInset(edge: .top) {
            if AppData.isDegraded {
                Label("Your saved chats couldn't be opened, so this session is temporary. Nothing was deleted. Restart the app, and update it if this keeps happening.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).padding(10).frame(maxWidth: .infinity).background(.yellow.opacity(0.25))
            }
        }
        .sheet(isPresented: $state.showPalette) {
            CommandPalette(state: state, records: records)
        }
        .onChange(of: AppRouter.shared.chatID) { _, id in
            if let id, records.contains(where: { $0.id == id }) { state.open(id); AppRouter.shared.chatID = nil }
        }
        .onAppear {
            state.context = context
            if state.selection == nil {
                if let recent = records.first(where: { !$0.isEmpty }) ?? records.first { state.open(recent.id) }
                else { state.newChat(in: context) }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .chat(let id):
            if let record = records.first(where: { $0.id == id }) {
                ChatScreen(state: state, record: record, records: records)
            } else {
                ContentUnavailableView("Chat not found", systemImage: "bubble.left")
            }
        case .models:
            ModelsView(state: state)
        case .hosts: HostsView()
        case .pullRequests: NavigationStack { PullRequestsView() }
        case .compare: NavigationStack { CompareView() }
        case .benchmark: NavigationStack { BenchmarkView() }
        case .finetune: NavigationStack { FineTuneView() }
        case .evals: NavigationStack { EvalView() }
        case .settings:
            SettingsView()
        case nil:
            ContentUnavailableView {
                Label("No chat open", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Press ⌘N to start one.")
            } actions: {
                Button("New Chat") { state.newChat(kind: .chat) }.buttonStyle(.borderedProminent)
            }
        }
    }
}
