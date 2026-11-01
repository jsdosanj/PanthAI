import AppIntents
import SwiftData
import SwiftUI

/// A chat in a desktop-style frame: tab strip, centered transcript, floating composer, inspector.
struct ChatScreen: View {
    @Environment(\.modelContext) private var context
    @Bindable var state: WindowState
    let record: ChatSessionRecord
    let records: [ChatSessionRecord]

    @Query private var workspaces: [WorkspaceRecord]
    private var model: ChatViewModel { state.viewModel(for: record, context: context) }

    /// Copies the conversation up to `index` into a new chat. With `edited`, that user message is replaced and re-sent.
    private func branch(at index: Int, edited: String?) {
        let source = model.turns
        let keep = edited == nil ? Array(source.prefix(index + 1)) : Array(source.prefix(index))
        let copy = ChatSessionRecord(providerKey: record.providerKey, kind: record.kind)
        copy.title = record.title.hasSuffix(" ⑂") ? record.title : record.title + " ⑂"
        copy.turns = keep
        copy.parentID = record.id
        copy.samplingData = record.samplingData; copy.schemaText = record.schemaText; copy.networkRaw = record.networkRaw
        copy.networkHostsData = record.networkHostsData; copy.agentIDString = record.agentIDString
        copy.tainted = record.tainted; copy.workspaceIDString = record.workspaceIDString; copy.pinnedData = record.pinnedData; copy.mcpData = record.mcpData; copy.modeRaw = record.modeRaw
        context.insert(copy)
        try? context.save()
        state.open(copy.id)
        if let edited {
            let branchModel = state.viewModel(for: copy, context: context)
            if let ws = model.workspace { branchModel.attach(ws) }
            Task { branchModel.send(edited) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(state: state, records: records)
            ChatPane(model: model)
        }
        .inspector(isPresented: $state.showInspector) {
            InspectorView(model: model).inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu("Share", systemImage: "square.and.arrow.up") {
                    ShareLink("Markdown", item: ChatFile(title: record.title, turns: model.turns, model: model.choice.label, format: .markdown),
                              preview: SharePreview(record.title))
                    ShareLink("JSON", item: ChatFile(title: record.title, turns: model.turns, model: model.choice.label, format: .json),
                              preview: SharePreview(record.title))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.trailing") { state.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(record.title)
        .focusedSceneValue(\.chatModel, model)
        .userActivity("com.dosanjhlabs.dosanjhai.chat", isActive: ChatIndexer.isEnabled && !record.isEmpty) { activity in
            // Lets Siri see which chat is on screen ("summarise this chat").
            activity.title = record.title
            activity.appEntityIdentifier = EntityIdentifier(for: ChatEntity(record))
        }
        .onAppear {
            if let ws = workspaces.first(where: { $0.id == record.workspaceID }) { model.attach(ws) }
            model.onBranch = { index, edited in branch(at: index, edited: edited) }
        }
        .alert("Send this chat to a cloud service?", isPresented: Binding(get: { model.pendingConsent != nil }, set: { if !$0 { model.pendingConsent = nil } })) {
            Button("Send to this provider") {
                if case .remote(let id, _) = model.pendingConsent { CloudConsent.accept(id) }
                if let choice = model.pendingConsent { model.pendingConsent = nil; model.select(choice) }
            }
            Button("Cancel", role: .cancel) { model.pendingConsent = nil }
        } message: {
            Text("Your messages, and any file, web page or tool output in this chat, will leave this iPad and go to the provider you chose. Their privacy policy applies, not DosanjhAI's.")
        }
        .sheet(isPresented: Bindable(model).showRepoPicker) { RepoPickerSheet(model: model) }
        .sheet(isPresented: Bindable(model).showHistorySearch) { PromptHistorySheet(model: model) }
        .sheet(isPresented: Bindable(model).showHelp) { ShortcutsHelp() }
    }
}

/// The chat itself, reused by the detached single-chat windows.
struct ChatPane: View {
    @Bindable var model: ChatViewModel
    private let readingWidth: CGFloat = 780

    var body: some View {
        Group {
            if case .unavailable(let reason) = model.status {
                ContentUnavailableView("Model unavailable", systemImage: "sparkles", description: Text(reason))
            } else if model.turns.isEmpty {
                EmptyChat(model: model)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(model.turns) { turn in
                                MessageRow(turn: turn, model: model, isLast: turn.id == model.turns.last?.id)
                                    .id(turn.id)
                            }
                            Color.clear.frame(height: 8).id("bottom")
                        }
                        .frame(maxWidth: readingWidth)
                        .padding(.horizontal, 24).padding(.top, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.turns.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: model.scrollTick) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        // The composer floats over the transcript; the system adds the scroll-edge effect beneath it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
                Composer(model: model)
            }
            .frame(maxWidth: readingWidth)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $model.pendingApproval, onDismiss: { if model.pendingApproval != nil { model.resolveApproval(.deny) } }) { approval in
            ApprovalSheet(approval: approval, model: model)
        }
    }
}

private struct MessageRow: View {
    let turn: ChatTurn
    let model: ChatViewModel
    let isLast: Bool
    @State private var hovering = false
    @State private var editing = false
    @State private var editedText = ""

    var body: some View {
        switch turn.role {
        case .tool:
            ToolTurnCard(turn: turn, model: model)
        case .user:
            Text(turn.text)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.text }
                    Button("Edit and branch…", systemImage: "arrow.triangle.branch") { editing = true }
                }
                .alert("Edit and branch", isPresented: $editing) {
                    TextField("Message", text: $editedText, axis: .vertical)
                    Button("Branch") {
                        if let i = model.turns.firstIndex(where: { $0.id == turn.id }) { model.onBranch?(i, editedText) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .onAppear { editedText = turn.text }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 80)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(Color.accentColor)
                    Text(model.choice.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                let visible = ToolProtocol.stripCall(from: turn.text)
                if turn.isSummary == true { Label("Earlier messages summarised", systemImage: "arrow.down.right.and.arrow.up.left").font(.caption).foregroundStyle(.secondary) }
                if visible.isEmpty { if turn.text.isEmpty { ProgressView().controlSize(.small) } } else { MarkdownText(text: visible) }
                if !turn.text.isEmpty, !(isLast && model.isStreaming) {
                    HStack(spacing: 0) {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.text }
                        if isLast { Button("Regenerate", systemImage: "arrow.clockwise") { model.regenerate() } }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .opacity(hovering || isLast ? 1 : 0.0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.text }
                Button("Branch from here", systemImage: "arrow.triangle.branch") {
                    if let i = model.turns.firstIndex(where: { $0.id == turn.id }) { model.onBranch?(i, nil) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Copy reply") { UIPasteboard.general.string = turn.text }
        }
    }
}

private struct Composer: View {
    @Bindable var model: ChatViewModel
    @FocusState private var focused: Bool
    @State private var showTemplates = false
    @AppStorage(Prefs.returnSends) private var returnSends = true
    @AppStorage(Prefs.focusOnLaunch) private var focusOnLaunch = true

    /// Claude Code's terminal keys, adapted for a Magic Keyboard.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            let sends = returnSends ? !press.modifiers.contains(.shift) : press.modifiers.contains(.command)
            guard sends else { return .ignored }
            model.send()
            return .handled
        case .escape:
            model.escape(); return .handled
        case .tab where press.modifiers.contains(.shift):
            model.cycleMode(); return .handled        // Shift-Tab cycles Ask / Auto-accept / Plan
        case .upArrow where model.input.isEmpty || model.historyCursor != nil:
            model.historyPrevious(); return .handled   // recall earlier prompts
        case .downArrow where model.historyCursor != nil:
            model.historyNext(); return .handled
        default:
            return .ignored
        }
    }

    private var slashMatches: [(name: String, help: String)] {
        guard model.input.hasPrefix("/"), !model.input.contains(" ") else { return [] }
        return ChatViewModel.slashCommands.filter { $0.name.hasPrefix(model.input.lowercased()) }
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if !slashMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(slashMatches, id: \.name) { command in
                            Button { model.input = command.name } label: {
                                HStack { Text(command.name).font(.body.monospaced()); Text(command.help).foregroundStyle(.secondary); Spacer() }
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
                HStack(spacing: 8) {
                    ModelChip(model: model)
                    if model.kind == .code {
                        Button { model.cycleMode() } label: { Label(model.mode.label, systemImage: model.mode.icon) }
                            .buttonStyle(.glass).controlSize(.small)
                            .accessibilityHint("Changes what the assistant may do without asking. Shift-Tab on a keyboard.")
                    }
                    Button { showTemplates = true } label: { Label("Templates", systemImage: "text.badge.plus") }
                        .buttonStyle(.glass).controlSize(.small)
                    Text("\(model.estimatedContextTokens.formatted()) tokens")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(model.kind == .code ? "Describe what to build, or paste code" : "Message DosanjhAI",
                              text: $model.input, axis: .vertical)
                        .font(model.kind == .code ? .system(.body, design: .monospaced) : .body)
                        .lineLimit(1...8)
                        .focused($focused)
                        .submitLabel(.send)
                        .padding(.vertical, 12).padding(.leading, 8)
                        .onKeyPress(phases: .down) { press in handle(press) }
                    Button {
                        model.isStreaming ? model.stop() : model.send()
                    } label: {
                        Image(systemName: model.isStreaming ? "stop.fill" : "arrow.up")
                            .font(.body.weight(.bold)).frame(minWidth: 28, minHeight: 28)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .disabled(!model.isStreaming && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(6)
                    .accessibilityLabel(model.isStreaming ? "Stop" : "Send")
                }
                .padding(.leading, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
            }
        }
        .task {
            guard focusOnLaunch else { return }
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .sheet(isPresented: $showTemplates) { TemplatePicker { model.input += ($0) } }
    }
}

private struct EmptyChat: View {
    let model: ChatViewModel
    private var actions: [(String, String, String)] {
        model.kind == .code ? [
            ("Build a feature", "hammer", "Plan and implement: "),
            ("Explain code", "text.magnifyingglass", "Explain what this code does, step by step:\n\n"),
            ("Fix a bug", "ant", "Find and fix the bug in this code:\n\n"),
            ("Write tests", "checkmark.seal", "Write unit tests for this code:\n\n"),
        ] : [
            ("Translate", "character.bubble", "Translate the following into Punjabi (Gurmukhi) and English: "),
            ("Read an image", "doc.text.viewfinder", "Extract all text from the image I attach and tidy the formatting."),
            ("Write code", "chevron.left.forwardslash.chevron.right", "Write a Swift function that "),
            ("Design", "paintpalette", "Design an SVG logo for "),
        ]
    }

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = 44

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: model.kind == .code ? "chevron.left.forwardslash.chevron.right" : "sparkles")
                .font(.system(size: heroSize)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(model.kind == .code ? "What are we building?" : "How can I help?").font(.largeTitle.weight(.semibold))
            Text("Private by design. Everything runs on your iPad unless you pick the advanced Apple model.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Responses are generated by AI and can be wrong. Check anything important.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            LazyVGrid(columns: [.init(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(actions, id: \.0) { title, icon, prompt in
                    Button { model.input = prompt } label: {
                        Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
            }
            .frame(maxWidth: 520)
            Spacer()
        }
        .padding()
    }
}

struct ModelChip: View {
    let model: ChatViewModel
    @Query(sort: \ProviderRecord.createdAt) private var providers: [ProviderRecord]
    @Query(sort: \SSHHostRecord.createdAt) private var sshHosts: [SSHHostRecord]

    var body: some View {
        Menu {
            Section("Apple") {
                ForEach(AppleModelKind.allCases) { kind in
                    Button(kind.title) { model.select(.apple(kind)) }
                }
            }
            let ready = CuratedModels.everything.filter { ModelManager.shared.isDownloaded($0.id) }
            if !ready.isEmpty {
                Section("Downloaded") {
                    ForEach(ready) { m in
                        Button { model.select(.mlx(m.id)) } label: {
                            if model.choice == .mlx(m.id) { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                        }
                    }
                }
            }
            ForEach(sshHosts) { host in
                Section("\(host.name) — your machine") {
                    ForEach(RemoteAgentKind.allCases, id: \.self) { agent in
                        Button { model.select(.ssh(host.id, agent.rawValue)) } label: {
                            if model.choice == .ssh(host.id, agent.rawValue) { Label(agent.title, systemImage: "checkmark") } else { Text(agent.title) }
                        }
                    }
                }
            }
            ForEach(providers) { provider in
                Section("\(provider.name) — \(provider.isLocalNetwork ? "your network" : "cloud")") {
                    ForEach(provider.models.prefix(40), id: \.self) { name in
                        Button { model.select(.remote(provider.id, name)) } label: {
                            if model.choice == .remote(provider.id, name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if model.isLoadingModel { ProgressView().controlSize(.mini) } else { Image(systemName: "cpu") }
                Text(model.choice.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
        }
        .buttonStyle(.glass).controlSize(.small)
        .accessibilityLabel("Model: \(model.choice.label)")
    }
}
