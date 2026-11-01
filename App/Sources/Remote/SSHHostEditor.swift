import SwiftData
import SwiftUI

struct SSHHostEditor: View {
    @Bindable var host: SSHHostRecord
    @Query(sort: \SSHKeyRecord.createdAt) private var keys: [SSHKeyRecord]
    @Query(sort: \SSHHostRecord.name) private var allHosts: [SSHHostRecord]
    @State private var password = ""
    @State private var ownKeyLine = ""
    @State private var status = ""
    @State private var pendingFingerprint: String?
    @State private var pendingFor = ""
    @State private var busy = false

    private var jump: SSHHostRecord? { allHosts.first { $0.id.uuidString == host.jumpHostIDString } }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $host.name)
                TextField("Host, IP or Tailscale name", text: $host.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $host.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                TextField("User name", text: $host.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Organise") {
                TextField("Group", text: $host.group)
                TextField("Tags, comma separated", text: $host.tagsRaw).textInputAutocapitalization(.never)
                Toggle("Favorite", isOn: $host.isFavorite)
                TextField("Notes", text: $host.notes, axis: .vertical).lineLimit(2...6)
            }
            Section {
                Picker("Sign in with", selection: $host.usesPassword) { Text("Key (recommended)").tag(false); Text("Password").tag(true) }
                if host.usesPassword {
                    SecureField("Password", text: $password).onSubmit(savePassword)
                    Button("Save password on this iPad", action: savePassword).disabled(password.isEmpty)
                } else {
                    Picker("Key", selection: $host.keyIDString) {
                        Text("A key just for this machine").tag("")
                        ForEach(keys) { Text($0.name).tag($0.id.uuidString) }
                    }
                    if host.keyIDString.isEmpty {
                        if ownKeyLine.isEmpty { Button("Create a key for this machine", systemImage: "key") { ownKeyLine = SSHService.generateKey(account: host.keyAccount) } }
                        else { Text(ownKeyLine).font(.caption.monospaced()).textSelection(.enabled) }
                    } else if let key = keys.first(where: { $0.id.uuidString == host.keyIDString }), let line = SSHService.publicKeyLine(account: key.account) {
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Copy public key", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = host.keyIDString.isEmpty ? ownKeyLine : keys.first(where: { $0.id.uuidString == host.keyIDString }).flatMap { SSHService.publicKeyLine(account: $0.account) }
                    }
                    Text("Add that line to ~/.ssh/authorized_keys on the machine. The private key stays on this iPad.").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Sign-in") }
            Section {
                Picker("Connect through", selection: $host.jumpHostIDString) {
                    Text("Directly").tag("")
                    ForEach(allHosts.filter { $0.id != host.id && $0.jumpHostIDString.isEmpty }) { Text($0.name).tag($0.id.uuidString) }
                }
            } header: { Text("Jump host") } footer: { Text("Reach a machine that is only visible from another one (ProxyJump).") }
            Section {
                Button(busy ? "Connecting…" : "Check connection and trust", systemImage: "checkmark.shield") { Task { await probe() } }.disabled(busy || host.host.isEmpty)
                if let pendingFingerprint {
                    Text("Does this match the machine's host key? No password or key was sent to find out.\n\(pendingFingerprint)").font(.footnote.monospaced())
                    Button("Trust this machine") {
                        if pendingFor == "\(host.host):\(host.port)" { host.trustedFingerprint = pendingFingerprint; status = "Trusted." }
                        else { status = "The address changed since the check. Check the connection again." }
                        self.pendingFingerprint = nil
                    }
                } else if !host.trustedFingerprint.isEmpty {
                    LabeledContent("Trusted key", value: host.trustedFingerprint).font(.caption)
                    Button("Forget trust", role: .destructive) { host.trustedFingerprint = "" }
                }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Identity") } footer: { Text("On the machine, run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub and compare. If the key ever changes, PanthAI refuses to connect.") }
            Section {
                TextField("Folder for Claude Code / Codex", text: $host.workingDirectory).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Shell", selection: $host.shell) { Text("zsh").tag("zsh"); Text("bash").tag("bash"); Text("sh").tag("sh") }
                Toggle("Let Claude Code and Codex edit files", isOn: $host.allowRemoteEdits)
                Picker("Terminal theme", selection: $host.themeName) { ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) } }
            } header: { Text("Terminal and agents") } footer: { Text("Off: Claude Code runs in read-only plan mode. On: it may edit files in that folder without asking, because no one can tap Allow over SSH.") }
        }
        .navigationTitle(host.name)
        .onAppear { ownKeyLine = Keychain.exists(host.keyAccount) ? (SSHService.publicKeyLine(account: host.keyAccount) ?? "") : "" }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        Keychain.set(password, for: host.passwordAccount, synchronizable: false, requireUserPresence: UserDefaults.standard.object(forKey: Prefs.protectKeys) as? Bool ?? true)
        password = ""; status = "Password saved on this iPad."
    }

    private func probe() async {
        busy = true; status = ""
        do { pendingFingerprint = try await SSHService.probe(host.snapshot(jump: jump)); pendingFor = "\(host.host):\(host.port)" }
        catch { status = error.localizedDescription }
        busy = false
    }
}
