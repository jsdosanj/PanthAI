import SwiftData
import SwiftUI

/// Repo + file tree shown in a code session's details panel.
struct WorkspaceSection: View {
    @Bindable var model: ChatViewModel

    private struct Node: Identifiable {
        let id: String
        let name: String
        let path: String
        var children: [Node]?
    }

    private func tree(for paths: [String]) -> [Node] {
        func build(_ paths: [String], prefix: String) -> [Node] {
            var folders: [String: [String]] = [:]
            var files: [Node] = []
            for path in paths {
                let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 { folders[parts[0], default: []].append(parts[1]) }
                else { files.append(Node(id: prefix + path, name: path, path: prefix + path, children: nil)) }
            }
            let dirs = folders.keys.sorted().map { name in
                Node(id: prefix + name + "/", name: name, path: prefix + name, children: build(folders[name]!, prefix: prefix + name + "/"))
            }
            return dirs + files.sorted { $0.name < $1.name }
        }
        return build(paths, prefix: "")
    }

    var body: some View {
        Section("Workspace") {
            if let workspace = model.workspace {
                LabeledContent("Repo", value: workspace.fullName)
                LabeledContent("Branch", value: workspace.branch)
                LabeledContent("Files", value: "\(workspace.fileCount)\(workspace.truncated ? "+" : "")")
                if workspace.truncated {
                    Text("Large repo: only part of it was downloaded (text files up to 200 KB).").font(.caption).foregroundStyle(.secondary)
                }
                Button("Detach", role: .destructive) { model.attach(nil) }
            } else {
                Button("Add GitHub repo…", systemImage: "arrow.down.circle") { model.showRepoPicker = true }
            }
        }
        if let workspace = model.workspace {
            Section("Files in context") {
                let pinned = model.record.pinnedPaths
                if pinned.isEmpty { Text("Tap files below to include them. Or type @filename in your message.").font(.caption).foregroundStyle(.secondary) }
                ForEach(pinned, id: \.self) { path in
                    Label(path, systemImage: "pin.fill").font(.caption).lineLimit(1)
                }
            }
            Section("Browse") {
                OutlineGroup(tree(for: WorkspaceFiles.paths(in: workspace)), children: \.children) { node in
                    Button { if node.children == nil { model.togglePinned(node.path) } } label: {
                        Label(node.name, systemImage: node.children != nil ? "folder" : (model.record.pinnedPaths.contains(node.path) ? "checkmark.circle.fill" : "doc.text"))
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Pick a GitHub repo (yours, or any public `owner/name`) and download it into the session.
struct RepoPickerSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let model: ChatViewModel
    @State private var repos: [GitHubRepo] = []
    @State private var manual = ""
    @State private var selected: GitHubRepo?
    @State private var branches: [String] = []
    @State private var branch = ""
    @State private var progress: Double?
    @State private var error: String?
    private let client = GitHubClient()

    var body: some View {
        NavigationStack {
            Form {
                if client.token == nil {
                    Section { Text("Add a GitHub token in Settings to see your private repos. Public repos work without one.").font(.footnote) }
                }
                Section("Any repo") {
                    TextField("owner/name", text: $manual).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Look up") { Task { await lookup(manual) } }.disabled(manual.isEmpty)
                }
                if !repos.isEmpty {
                    Section("Your repos") {
                        ForEach(repos) { repo in
                            Button { Task { await choose(repo) } } label: {
                                HStack {
                                    Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                                    VStack(alignment: .leading) {
                                        Text(repo.fullName)
                                        if let d = repo.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    if selected?.id == repo.id { Spacer(); Image(systemName: "checkmark") }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let selected {
                    Section(selected.fullName) {
                        Picker("Branch", selection: $branch) { ForEach(branches, id: \.self) { Text($0).tag($0) } }
                        if let progress {
                            ProgressView(value: progress) { Text("Downloading…") }
                        } else {
                            Button("Load into session", systemImage: "square.and.arrow.down") { Task { await load(selected) } }
                                .buttonStyle(.borderedProminent).disabled(branch.isEmpty)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("GitHub repo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { if client.token != nil { repos = (try? await client.repos()) ?? [] } }
        }
    }

    private func lookup(_ name: String) async {
        do { await choose(try await client.repo(name.trimmingCharacters(in: .whitespaces))) }
        catch { self.error = error.localizedDescription }
    }

    private func choose(_ repo: GitHubRepo) async {
        selected = repo; error = nil
        branches = (try? await client.branches(repo.fullName)) ?? [repo.defaultBranch]
        branch = branches.contains(repo.defaultBranch) ? repo.defaultBranch : (branches.first ?? "")
    }

    private func load(_ repo: GitHubRepo) async {
        progress = 0; error = nil
        let folder = "\(repo.fullName.replacingOccurrences(of: "/", with: "__"))__\(branch.replacingOccurrences(of: "/", with: "_"))"
        let record = WorkspaceRecord(fullName: repo.fullName, branch: branch, folderName: folder)
        do {
            let result = try await WorkspaceImporter.download(fullName: repo.fullName, branch: branch, to: record.folderURL) { value in
                Task { @MainActor in progress = value }
            }
            record.fileCount = result.fileCount; record.totalBytes = result.totalBytes; record.truncated = result.truncated
            context.insert(record)
            try? context.save()
            model.attach(record)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            progress = nil
        }
    }
}

/// Ctrl-R: search earlier prompts and reuse one.
struct PromptHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatViewModel
    @State private var query = ""
    private var matches: [String] {
        let all = model.promptHistory.reversed() as [String]
        return query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(matches, id: \.self) { prompt in
                Button(prompt) { model.input = prompt; dismiss() }.lineLimit(2)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search prompt history")
            .navigationTitle("Prompt history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ShortcutsHelp: View {
    @Environment(\.dismiss) private var dismiss
    private let rows: [(String, [(String, String)])] = [
        ("Composer", [("Return", "Send (Shift-Return: new line)"), ("Esc", "Interrupt; again clears input"), ("Esc Esc", "Rewind last exchange"),
                      ("↑ / ↓", "Prompt history"), ("⌃R", "Search prompt history"), ("⇧Tab", "Cycle Ask / Auto-accept / Plan"),
                      ("⌃C", "Interrupt or clear input"), ("⌃L", "Scroll to latest"), ("/", "Slash commands")]),
        ("Chats", [("⌘N", "New chat"), ("⇧⌘N", "New code session"), ("⌘K", "Command palette"), ("⌘W", "Close tab"),
                   ("⇧⌘[ / ⇧⌘]", "Previous / next tab"), ("⌥P", "Next model"), ("⌃O", "Toggle details"), ("⇧⌘C", "Copy last reply")]),
        ("Code sessions", [("@file", "Add a repo file to context"), ("/repo", "Attach a GitHub repo")]),
    ]
    var body: some View {
        NavigationStack {
            List {
                ForEach(rows, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1, id: \.0) { key, text in
                            LabeledContent { Text(text).foregroundStyle(.secondary) } label: { Text(key).font(.body.monospaced()) }
                        }
                    }
                }
            }
            .navigationTitle("Keyboard shortcuts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
