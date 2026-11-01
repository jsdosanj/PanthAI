import SwiftData
import SwiftUI

struct ConnectorsSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MCPServerRecord.createdAt) private var servers: [MCPServerRecord]
    @State private var adding = false

    var body: some View {
        Section {
            ForEach(servers) { server in
                NavigationLink { ConnectorDetail(server: server) } label: {
                    VStack(alignment: .leading) {
                        Text(server.name)
                        Text(server.hasCredentials ? "Signed in" : "Not signed in").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets {
                    Keychain.delete(servers[i].tokenAccount); Keychain.delete(servers[i].oauthAccount)
                    MCPHub.shared.forget(servers[i].id); context.delete(servers[i])
                }
                try? context.save()
            }
            Button("Add connector…", systemImage: "plus") { adding = true }
        } header: {
            Text("Connectors (MCP)")
        } footer: {
            Text("Connectors let the assistant use outside services. Each tool call asks for your approval, and connectors are off until you switch them on in a chat's details.")
        }
        .sheet(isPresented: $adding) { AddConnectorSheet() }
    }
}

struct AddConnectorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var preset = MCPPreset.all[0]
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Service", selection: $preset) { ForEach(MCPPreset.all) { Text($0.name).tag($0) } }
                Text(preset.note).font(.footnote).foregroundStyle(.secondary)
                TextField("Name", text: $name)
                TextField("Server address (https)", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            }
            .navigationTitle("Add connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        context.insert(MCPServerRecord(name: name, url: url)); try? context.save(); dismiss()
                    }.disabled(name.isEmpty || !url.hasPrefix("https://") || url.count < 12)
                }
            }
            .onChange(of: preset, initial: true) { _, new in name = new.id == "custom" ? "" : new.name; url = new.url }
        }
    }
}

struct ConnectorDetail: View {
    @Bindable var server: MCPServerRecord
    @State private var token = ""
    private let hub = MCPHub.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: server.url)
                statusRow
                Button("Sign in with the service", systemImage: "person.badge.key") { Task { await hub.signIn(server) } }
                SecureField("Or paste an access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit {
                        guard !token.isEmpty else { return }
                        Keychain.set(token, for: server.tokenAccount); token = ""
                        Task { await hub.connect(server) }
                    }
                Button("Check connection", systemImage: "arrow.clockwise") { Task { await hub.connect(server) } }
            }
            Section {
                Toggle("Read-only tools only", isOn: $server.readOnly)
            } footer: {
                Text("On: the assistant only sees tools the service marks as read-only. Turn off to let it make changes, with your approval on every call.")
            }
            Section { NavigationLink("Inspector: traffic and manual calls") { MCPInspectorView(server: server) } }
            Section("Tools") {
                ForEach(hub.tools[server.id] ?? []) { tool in
                    VStack(alignment: .leading) {
                        HStack { Text(tool.name).font(.callout.monospaced()); if tool.readOnly { Text("read-only").font(.caption2).foregroundStyle(.secondary) } }
                        Text(tool.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(server.name)
        .task { if hub.tools[server.id] == nil { await hub.connect(server) } }
    }

    @ViewBuilder private var statusRow: some View {
        switch hub.status[server.id] ?? .idle {
        case .idle: LabeledContent("Status", value: "Not checked")
        case .connecting: HStack { Text("Status"); Spacer(); ProgressView() }
        case .ready(let n): LabeledContent("Status", value: "Connected · \(n) tools")
        case .needsSignIn: LabeledContent("Status", value: "Sign in required")
        case .failed(let message): VStack(alignment: .leading) { Text("Status"); Text(message).font(.caption).foregroundStyle(.red) }
        }
    }
}
