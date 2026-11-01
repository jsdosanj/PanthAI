import Crypto
import SwiftData
import SwiftUI

/// A reusable SSH key, shareable across machines.
@Model
final class SSHKeyRecord {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    init(name: String) { self.name = name }
    var account: String { "sshkey.\(id.uuidString)" }
}

/// A saved command, to insert into a terminal or run on several machines at once.
@Model
final class SnippetRecord {
    var id: UUID = UUID()
    var name: String = ""
    var command: String = ""
    var createdAt: Date = Date.now
    init(name: String, command: String) { self.name = name; self.command = command }
}

struct KeyManagerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SSHKeyRecord.createdAt) private var keys: [SSHKeyRecord]
    @State private var importing = false
    @State private var importName = ""
    @State private var importText = ""
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key.name).font(.headline)
                        if let line = SSHService.publicKeyLine(account: key.account) {
                            Text(line).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                            Button("Copy public key", systemImage: "doc.on.doc") { UIPasteboard.general.string = line }.font(.caption).buttonStyle(.borderless)
                        }
                    }
                }
                .onDelete { offsets in for i in offsets { Keychain.delete(keys[i].account); context.delete(keys[i]) }; try? context.save() }
            } footer: { Text("Keys are stored on this iPad only and never leave it. Add the public key to ~/.ssh/authorized_keys on each machine.") }
            Section {
                Button("Generate a new key", systemImage: "key") {
                    let key = SSHKeyRecord(name: "Key \(keys.count + 1)")
                    _ = SSHService.generateKey(account: key.account)
                    context.insert(key); try? context.save()
                }
                Button("Import an OpenSSH Ed25519 key…", systemImage: "square.and.arrow.down") { importing = true }
            }
        }
        .navigationTitle("SSH keys")
        .sheet(isPresented: $importing) {
            NavigationStack {
                Form {
                    TextField("Name", text: $importName)
                    TextField("-----BEGIN OPENSSH PRIVATE KEY-----", text: $importText, axis: .vertical).font(.caption.monospaced()).lineLimit(6...14).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passphrase, if the key has one", text: $passphrase)
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Text("Only Ed25519 keys are supported. Paste the private key, then delete it from the clipboard.").font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("Import key").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { importing = false; importText = ""; passphrase = "" } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            let key = SSHKeyRecord(name: importName.isEmpty ? "Imported key" : importName)
                            do { _ = try SSHService.importKey(openSSH: importText, passphrase: passphrase, account: key.account); context.insert(key); try? context.save(); importing = false; importText = ""; passphrase = ""; error = nil }
                            catch { self.error = "Couldn't read that key. Is it an Ed25519 OpenSSH key?" }
                        }.disabled(importText.isEmpty)
                    }
                }
            }
        }
    }
}

struct SnippetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SnippetRecord.createdAt) private var snippets: [SnippetRecord]
    @Query(sort: \SSHHostRecord.name) private var hosts: [SSHHostRecord]
    @State private var running: SnippetRecord?

    var body: some View {
        List {
            ForEach(snippets) { snippet in
                NavigationLink {
                    Form {
                        TextField("Name", text: Bindable(snippet).name)
                        TextField("Command", text: Bindable(snippet).command, axis: .vertical).font(.body.monospaced()).lineLimit(2...10).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Run on several machines…", systemImage: "rectangle.stack.badge.play") { running = snippet }
                    }.navigationTitle(snippet.name)
                } label: { VStack(alignment: .leading) { Text(snippet.name); Text(snippet.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) } }
            }
            .onDelete { offsets in for i in offsets { context.delete(snippets[i]) }; try? context.save() }
        }
        .overlay { if snippets.isEmpty { ContentUnavailableView("No snippets", systemImage: "text.alignleft", description: Text("Save commands you run often.")) } }
        .navigationTitle("Snippets")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("New snippet", systemImage: "plus") { context.insert(SnippetRecord(name: "New snippet", command: "uptime")); try? context.save() } } }
        .sheet(item: $running) { MultiExecSheet(snippet: $0, hosts: hosts) }
    }
}

/// Runs one command on several machines at once and shows each result.
struct MultiExecSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snippet: SnippetRecord
    let hosts: [SSHHostRecord]
    @State private var selected: Set<UUID> = []
    @State private var results: [UUID: String] = [:]
    @State private var running = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Machines") {
                    ForEach(hosts) { host in
                        Button { if selected.contains(host.id) { selected.remove(host.id) } else { selected.insert(host.id) } } label: {
                            HStack { Text(host.name); Spacer(); if selected.contains(host.id) { Image(systemName: "checkmark") } }
                        }.foregroundStyle(.primary)
                    }
                }
                Section { Text(snippet.command).font(.callout.monospaced()) ; Button(running ? "Running…" : "Run", systemImage: "play.fill") { Task { await run() } }.disabled(selected.isEmpty || running) }
                ForEach(hosts.filter { results[$0.id] != nil }) { host in
                    Section(host.name) { Text(results[host.id] ?? "").font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            .navigationTitle("Run on machines").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func run() async {
        running = true; results = [:]
        let command = snippet.command
        if let problem = RemoteCommandGuard.problem(with: command) { for id in selected { results[id] = problem }; running = false; return }
        let targets = hosts.filter { selected.contains($0.id) }.map { ($0.id, $0.snapshot) }
        await withTaskGroup(of: (UUID, String).self) { group in
            for (id, snapshot) in targets {
                group.addTask { (id, (try? await SSHService.run(snapshot, command: command)) ?? "Couldn't connect.") }
            }
            for await (id, text) in group { results[id] = text }
        }
        running = false
    }
}
