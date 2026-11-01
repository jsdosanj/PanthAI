import SwiftData
import SwiftUI
import UIKit

/// The iPadOS menu bar (hold ⌘ for the shortcut sheet). Terminal-style keys follow Claude Code's.
struct AppCommands: Commands {
    @FocusedValue(\.windowState) private var state
    @FocusedValue(\.chatModel) private var chat

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { state?.newChat(kind: .chat) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Code Session") { state?.newChat(kind: .code) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Command Palette…") { state?.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Close Tab") { if case .chat(let id) = state?.selection { state?.closeTab(id, records: []) } }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Details") { state?.showInspector.toggle() }
                .keyboardShortcut("o", modifiers: .control)
            Button("Models") { state?.selection = .models }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Settings") { state?.selection = .settings }
                .keyboardShortcut(",", modifiers: .command)
            Button("Previous Tab") { state?.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { state?.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
        CommandMenu("Session") {
            Button("Interrupt") { chat?.interrupt() }
                .keyboardShortcut("c", modifiers: .control)
            Button("Scroll to Latest") { chat?.scrollTick += 1 }
                .keyboardShortcut("l", modifiers: .control)
            Button("Search Prompt History") { chat?.showHistorySearch = true }
                .keyboardShortcut("r", modifiers: .control)
            Button("Next Model") { chat?.cycleModel() }
                .keyboardShortcut("p", modifiers: .option)
            Button("Copy Last Reply") {
                if let reply = chat?.turns.last(where: { $0.role == .assistant }) { UIPasteboard.general.string = reply.text }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { chat?.showHelp = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}
