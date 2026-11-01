import SwiftData
import SwiftUI

enum HostRoute: Hashable { case terminal(UUID), files(UUID), edit(UUID), keys, snippets }

/// The vault: every machine, grouped, searchable, with favourites and quick connect.
struct HostsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SSHHostRecord.name) private var hosts: [SSHHostRecord]
    @Query(sort: \SSHKeyRecord.createdAt) private var keys: [SSHKeyRecord]
    @State private var path: [HostRoute] = []
    @State private var search = ""
    @State private var quick = ""
    @State private var pendingDelete: SSHHostRecord?

    private var filtered: [SSHHostRecord] {
        guard !search.isEmpty else { return hosts }
        return hosts.filter { [$0.name, $0.host, $0.username, $0.group, $0.tagsRaw].contains { $0.localizedCaseInsensitiveContains(search) } }
    }
    private var groups: [(String, [SSHHostRecord])] {
        let favorites = filtered.filter(\.isFavorite)
        var result: [(String, [SSHHostRecord])] = favorites.isEmpty ? [] : [("Favorites", favorites)]
        let byGroup = Dictionary(grouping: filtered) { $0.group.isEmpty ? "Machines" : $0.group }
        result += byGroup.keys.sorted().map { ($0, byGroup[$0] ?? []) }
        return result
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    TextField("Quick connect: user@host:port", text: $quick)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { quickConnect() }
                }
                ForEach(groups, id: \.0) { group in
                    Section(group.0) { ForEach(group.1) { host in row(host) } }
                }
            }
            .overlay { if hosts.isEmpty { ContentUnavailableView("No machines yet", systemImage: "server.rack", description: Text("Add your Mac, a server or a Raspberry Pi. Over Tailscale it works from anywhere.")) } }
            .searchable(text: $search, prompt: "Search machines")
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("Add machine", systemImage: "plus") { addHost() } }
                ToolbarItem(placement: .secondaryAction) { Button("SSH keys", systemImage: "key") { path.append(.keys) } }
                ToolbarItem(placement: .secondaryAction) { Button("Snippets", systemImage: "text.alignleft") { path.append(.snippets) } }
            }
            .navigationDestination(for: HostRoute.self) { route in
                switch route {
                case .terminal(let id): if let host = hosts.first(where: { $0.id == id }) { TerminalScreen(host: host, hosts: hosts) }
                case .files(let id): if let host = hosts.first(where: { $0.id == id }) { SFTPBrowserView(host: host.snapshot(jump: hosts.first { $0.id.uuidString == host.jumpHostIDString })) }
                case .edit(let id): if let host = hosts.first(where: { $0.id == id }) { SSHHostEditor(host: host) }
                case .keys: KeyManagerView()
                case .snippets: SnippetsView()
                }
            }
            .confirmationDialog("Remove this machine?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { host in
                Button("Remove", role: .destructive) { Keychain.delete(host.keyAccount); Keychain.delete(host.passwordAccount); context.delete(host); try? context.save() }
            } message: { _ in Text("Its saved key or password is deleted from this iPad. Nothing changes on the machine.") }
        }
    }

    private func row(_ host: SSHHostRecord) -> some View {
        Button { host.lastConnected = .now; path.append(host.trustedFingerprint.isEmpty ? .edit(host.id) : .terminal(host.id)) } label: {
            HStack {
                Image(systemName: host.isFavorite ? "star.fill" : "server.rack").foregroundStyle(host.isFavorite ? .yellow : Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).foregroundStyle(.primary)
                    Text(host.trustedFingerprint.isEmpty ? "Needs setup — tap to trust this machine" : "\(host.username)@\(host.host)")
                        .font(.caption).foregroundStyle(host.trustedFingerprint.isEmpty ? Color.orange : .secondary)
                    if !host.tags.isEmpty { Text(host.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                if let last = host.lastConnected { Text(last.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .contextMenu {
            Button("Open terminal", systemImage: "terminal") { path.append(.terminal(host.id)) }
            Button("Open in new window", systemImage: "macwindow.badge.plus") { openWindow(id: "terminal", value: host.id) }
            Button("Files", systemImage: "folder") { path.append(.files(host.id)) }
            Button(host.isFavorite ? "Remove favorite" : "Favorite", systemImage: "star") { host.isFavorite.toggle() }
            Button("Edit", systemImage: "pencil") { path.append(.edit(host.id)) }
            Button("Remove…", systemImage: "trash", role: .destructive) { pendingDelete = host }
        }
        .swipeActions(edge: .trailing) { Button("Remove", role: .destructive) { pendingDelete = host } }
        .swipeActions(edge: .leading) { Button("Files", systemImage: "folder") { path.append(.files(host.id)) }.tint(.blue) }
    }

    private func addHost() {
        let host = SSHHostRecord(name: "New machine", host: "", username: "")
        host.keyIDString = keys.first?.id.uuidString ?? ""
        context.insert(host); try? context.save()
        path.append(.edit(host.id))
    }

    private func quickConnect() {
        let text = quick.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var user = NSUserName(), hostPart = text
        if let at = text.firstIndex(of: "@") { user = String(text[..<at]); hostPart = String(text[text.index(after: at)...]) }
        var port = 22
        if let colon = hostPart.lastIndex(of: ":"), let p = Int(hostPart[hostPart.index(after: colon)...]) { port = p; hostPart = String(hostPart[..<colon]) }
        let host = SSHHostRecord(name: hostPart, host: hostPart, username: user)
        host.port = port
        host.keyIDString = keys.first?.id.uuidString ?? ""
        context.insert(host); try? context.save()
        quick = ""
        path.append(.edit(host.id))
    }
}

struct TerminalScreen: View {
    @Bindable var host: SSHHostRecord
    let hosts: [SSHHostRecord]
    @State private var session: TerminalSession?
    @State private var fontSize: CGFloat = 14
    @State private var showSuggest = false
    @Query(sort: \SnippetRecord.createdAt) private var snippets: [SnippetRecord]

    var body: some View {
        Group {
            if let session {
                TerminalRepresentable(session: session, theme: TerminalTheme.named(host.themeName), fontSize: fontSize)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .overlay(alignment: .top) { banner(session) }
            } else { ProgressView() }
        }
        .background(Color(TerminalTheme.named(host.themeName).background))
        .navigationTitle(session?.title.isEmpty == false ? session!.title : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Suggest a command", systemImage: "sparkles") { showSuggest = true } }
            ToolbarItem(placement: .secondaryAction) {
                Menu("Snippets", systemImage: "text.alignleft") {
                    ForEach(snippets) { s in Button(s.name) { session?.type(s.command) } }
                    if snippets.isEmpty { Text("No snippets yet") }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu("Appearance", systemImage: "paintpalette") {
                    Picker("Theme", selection: $host.themeName) { ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) } }
                    Stepper("Font size \(Int(fontSize))", value: $fontSize, in: 9...28)
                }
            }
            ToolbarItem(placement: .secondaryAction) { Button("Reconnect", systemImage: "arrow.clockwise") { session?.reconnect() } }
        }
        .onAppear { if session == nil { session = TerminalSession(host: host.snapshot(jump: hosts.first { $0.id.uuidString == host.jumpHostIDString })) } }
        .onDisappear { session?.stop() }
        .sheet(isPresented: $showSuggest) { CommandSuggestSheet(host: host) { session?.type($0) } }
    }

    @ViewBuilder private func banner(_ session: TerminalSession) -> some View {
        switch session.state {
        case .connecting: Label("Connecting…", systemImage: "network").padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 8)
        case .closed(let reason):
            VStack(spacing: 6) {
                Text(reason ?? "Session ended").font(.footnote)
                Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }.buttonStyle(.borderedProminent).controlSize(.small)
            }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.top, 8)
        case .connected: EmptyView()
        }
    }
}

/// Describe what you want; the model suggests a command to review. It is typed at the prompt, never run for you.
struct CommandSuggestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: SSHHostRecord
    let onUse: (String) -> Void
    @State private var request = ""
    @State private var command = ""
    @State private var warning: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to do on \(host.name)?", text: $request, axis: .vertical).lineLimit(2...5)
                    Button(busy ? "Thinking…" : "Suggest", systemImage: "sparkles") { Task { await suggest() } }.disabled(request.isEmpty || busy)
                }
                if !command.isEmpty {
                    Section("Suggested command") {
                        Text(command).font(.body.monospaced()).textSelection(.enabled)
                        if let warning { Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote) }
                        Button("Type it at the prompt", systemImage: "terminal") { onUse(command); dismiss() }.disabled(warning != nil)
                    }
                    Section { Text("Read it before you press Return. Suggestions can be wrong.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Suggest a command").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func suggest() async {
        busy = true; warning = nil
        let ask = "Give ONE shell command for \(host.shell) on a Unix-like machine that does this: \(request)\nReply with only the command in a ```sh code block, nothing else. Prefer safe, read-only flags."
        let reply = await Generator.run(.lastUsed, prompt: ask, sampling: SamplingSettings(temperature: 0.2, maxTokens: 200))
        var text = reply.text
        if let r = text.range(of: #"```(?:sh|bash|zsh)?\s*\n([\s\S]*?)\n?```"#, options: .regularExpression) {
            text = String(text[r]).replacingOccurrences(of: #"^```(?:sh|bash|zsh)?\s*\n|\n?```$"#, with: "", options: .regularExpression)
        }
        command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        warning = RemoteCommandGuard.problem(with: command)
        busy = false
    }
}
