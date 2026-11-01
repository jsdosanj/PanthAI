import SwiftUI
import UniformTypeIdentifiers

/// A full SFTP file manager: browse, view, edit, upload (picker or drag and drop), download to Files, rename, delete, new folder.
struct SFTPBrowserView: View {
    let host: SSHHostSnapshot
    @State private var path = "."
    @State private var items: [SSHService.RemoteItem] = []
    @State private var error: String?
    @State private var busy = false
    @State private var editing: (path: String, name: String, text: String)?
    @State private var importing = false
    @State private var renaming: SSHService.RemoteItem?
    @State private var newName = ""
    @State private var deleting: SSHService.RemoteItem?
    @State private var makingFolder = false
    @State private var downloaded: URL?

    private func full(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Section(path) {
                Button("..", systemImage: "arrow.turn.up.left") { go((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent) }
                ForEach(items) { item in
                    Button {
                        if item.isDirectory { go(full(item.name)) } else { Task { await open(item) } }
                    } label: {
                        HStack {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text").foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                            Text(item.name)
                            Spacer()
                            if let size = item.size, !item.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .contextMenu {
                        if !item.isDirectory { Button("Download to Files", systemImage: "arrow.down.circle") { Task { await download(item) } } }
                        Button("Rename…", systemImage: "pencil") { renaming = item; newName = item.name }
                        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = item }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deleting = item } }
                }
            }
            if let downloaded { Section { ShareLink("Open downloaded file", item: downloaded) } }
        }
        .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .navigationTitle(host.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Upload", systemImage: "arrow.up.doc") { importing = true } }
            ToolbarItem(placement: .secondaryAction) { Button("New folder", systemImage: "folder.badge.plus") { makingFolder = true; newName = "" } }
            ToolbarItem(placement: .secondaryAction) { Button("Refresh", systemImage: "arrow.clockwise") { go(path) } }
        }
        .task { await load() }
        .dropDestination(for: URL.self) { urls, _ in Task { for url in urls { await upload(url) }; await load() }; return true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { for url in urls { await upload(url) }; await load() } }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let item = renaming { Task { await rename(item) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: $makingFolder) {
            TextField("Name", text: $newName)
            Button("Create") { Task { await makeFolder() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete from \(host.name)", role: .destructive) { if let item = deleting { Task { await remove(item) } } }
        } message: { Text("This deletes it on the machine and can't be undone.") }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) { editor }
    }

    private var editor: some View {
        NavigationStack {
            TextEditor(text: Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 }))
                .font(.system(.callout, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().padding(8)
                .navigationTitle(editing?.name ?? "").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { editing = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save to machine") { Task { await save() } } }
                }
        }
    }

    private func go(_ newPath: String) { path = newPath; Task { await load() } }

    private func run(_ work: () async throws -> Void) async {
        busy = true; error = nil
        do { try await work() } catch { self.error = error.localizedDescription }
        busy = false
    }

    private func load() async { await run { let r = try await SSHService.list(host, path: path); path = r.resolved; items = r.items } }

    private func open(_ item: SSHService.RemoteItem) async {
        await run {
            guard (item.size ?? 0) < 400_000 else { throw RemoteError(message: "That file is too big to edit here. Download it instead.") }
            let data = try await SSHService.read(host, path: full(item.name))
            guard let text = String(data: data, encoding: .utf8) else { throw RemoteError(message: "That isn't a text file. Download it instead.") }
            editing = (full(item.name), item.name, text)
        }
    }

    private func save() async {
        guard let editing else { return }
        await run { try await SSHService.write(host, path: editing.path, data: Data(editing.text.utf8)); self.editing = nil; await load() }
    }

    private func download(_ item: SSHService.RemoteItem) async {
        await run {
            let data = try await SSHService.read(host, path: full(item.name), limit: 50_000_000)
            let safeHost = host.name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
            let folder = FilesFolder.root.appending(path: "Downloads/\(safeHost)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let leaf = URL(filePath: item.name).lastPathComponent   // a server can send "../x"; keep only the last part
            guard !leaf.isEmpty, leaf != "..", leaf != "." else { throw RemoteError(message: "That file name isn't safe to save.") }
            let url = folder.appending(path: leaf)
            try data.write(to: url)
            downloaded = url
        }
    }

    private func upload(_ url: URL) async {
        await run {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL else { throw RemoteError(message: "Only files can be uploaded.") }   // a dropped web link would bypass offline mode
            let data = try Data(contentsOf: url)
            try await SSHService.write(host, path: full(url.lastPathComponent), data: data)
        }
    }

    private func rename(_ item: SSHService.RemoteItem) async {
        await run { try await SSHService.rename(host, from: full(item.name), to: full(newName)); renaming = nil; await load() }
    }

    private func remove(_ item: SSHService.RemoteItem) async {
        await run { try await SSHService.remove(host, path: full(item.name), isDirectory: item.isDirectory); deleting = nil; await load() }
    }

    private func makeFolder() async {
        await run { try await SSHService.makeDirectory(host, path: full(newName)); await load() }
    }
}
