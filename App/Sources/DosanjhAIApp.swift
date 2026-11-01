import SwiftData
import SwiftUI

@main
struct DosanjhAIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        // Each window has its own sidebar selection, tabs and inspector (multi-window / Stage Manager).
        WindowGroup {
            RootShell().privacyShield().task { DataProtection.apply() }
        }
        .modelContainer(AppData.container)
        .commands { AppCommands() }

        // A terminal in its own window.
        WindowGroup("Terminal", id: "terminal", for: UUID.self) { $id in
            TerminalWindow(id: id).privacyShield()
        }
        .modelContainer(AppData.container)

        // A single chat popped out into its own window.
        WindowGroup("Chat", id: "chat", for: UUID.self) { $id in
            DetachedChat(id: id).privacyShield()
        }
        .modelContainer(AppData.container)
    }
}

private struct DetachedChat: View {
    let id: UUID?
    @Environment(\.modelContext) private var context
    @Query private var records: [ChatSessionRecord]
    @State private var state = WindowState()

    var body: some View {
        if let record = records.first(where: { $0.id == id }) {
            NavigationStack {
                ChatPane(model: state.viewModel(for: record, context: context))
                    .toolbar { ToolbarItem(placement: .principal) { ModelChip(model: state.viewModel(for: record, context: context)) } }
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationTitle(record.title)
            }
        } else {
            ContentUnavailableView("Chat not found", systemImage: "bubble.left")
        }
    }
}
