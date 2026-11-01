import SwiftData
import SwiftUI

enum SidebarItem: Hashable {
    case chat(UUID)
    case models
    case knowledge
    case hosts
    case pullRequests
    case compare
    case benchmark
    case finetune
    case evals
    case settings
}

/// Per-window UI state, so every iPadOS window has its own selection and tabs.
@MainActor @Observable
final class WindowState {
    var selection: SidebarItem?
    var openTabs: [UUID] = []
    var showInspector = false
    var showPalette = false
    var columnVisibility: NavigationSplitViewVisibility = .all
    var searchText = ""
    var sidebarKind: SessionKind = .chat
    /// Set by the window so menu-bar commands can create chats.
    var context: ModelContext?
    private var viewModels: [UUID: ChatViewModel] = [:]

    func viewModel(for record: ChatSessionRecord, context: ModelContext) -> ChatViewModel {
        if let existing = viewModels[record.id] { return existing }
        if let shared = ChatRegistry.model(record.id) { viewModels[record.id] = shared; return shared }   // pop-out windows share the running chat
        let model = ChatViewModel(record: record) { try? context.save() }
        viewModels[record.id] = model
        return model
    }

    func forget(_ id: UUID) {
        (viewModels[id] ?? ChatRegistry.model(id))?.stop()
        viewModels[id] = nil
        openTabs.removeAll { $0 == id }
        if selection == .chat(id) { selection = nil }
    }

    @discardableResult
    func newChat(in context: ModelContext, choice: ProviderChoice? = nil, kind: SessionKind = .chat, agent: AgentRecord? = nil) -> ChatSessionRecord {
        let preferred = agent.flatMap { $0.providerKey.isEmpty ? nil : ProviderChoice(key: $0.providerKey) }
        let record = ChatSessionRecord(providerKey: (choice ?? preferred ?? .lastUsed).key, kind: kind)
        record.agentID = agent?.id
        context.insert(record)
        try? context.save()
        open(record.id)
        return record
    }

    func newChat(kind: SessionKind) {
        guard let context else { return }
        sidebarKind = kind
        newChat(in: context, kind: kind)
    }

    func cycleTab(_ step: Int) {
        guard case .chat(let current) = selection, let index = openTabs.firstIndex(of: current), !openTabs.isEmpty else { return }
        selection = .chat(openTabs[(index + step + openTabs.count) % openTabs.count])
    }

    func open(_ id: UUID) {
        if !openTabs.contains(id) { openTabs.append(id) }
        selection = .chat(id)
    }

    func closeTab(_ id: UUID, records: [ChatSessionRecord]) {
        guard let index = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: index)
        if selection == .chat(id) {
            let neighbor = openTabs.indices.contains(index) ? openTabs[index] : openTabs.last
            selection = neighbor.map { .chat($0) }
        }
    }
}

struct WindowStateKey: FocusedValueKey { typealias Value = WindowState }
extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateKey.self] }
        set { self[WindowStateKey.self] = newValue }
    }
}

struct ChatModelKey: FocusedValueKey { typealias Value = ChatViewModel }
extension FocusedValues {
    var chatModel: ChatViewModel? {
        get { self[ChatModelKey.self] }
        set { self[ChatModelKey.self] = newValue }
    }
}
