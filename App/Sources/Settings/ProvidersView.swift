import SwiftData
import SwiftUI

struct ProvidersSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ProviderRecord.createdAt) private var providers: [ProviderRecord]
    @State private var adding = false

    var body: some View {
        Section {
            ForEach(providers) { provider in
                NavigationLink {
                    ProviderDetail(provider: provider)
                } label: {
                    VStack(alignment: .leading) {
                        Text(provider.name)
                        Text("\(provider.models.count) models · \(provider.isLocalNetwork ? "your network" : "cloud")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { Keychain.delete(providers[i].keyAccount); context.delete(providers[i]) }
                try? context.save()
            }
            Button("Add provider…", systemImage: "plus") { adding = true }
        } header: {
            Text("Model providers")
        } footer: {
            Text("Cloud providers receive your messages. Add LM Studio or Ollama to use models running on your own Mac, over your network or Tailscale.")
        }
        .sheet(isPresented: $adding) { AddProviderSheet() }
    }
}

struct AddProviderSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var preset = ProviderPreset.all[0]
    @State private var name = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var models: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $preset) { ForEach(ProviderPreset.all) { Text($0.name).tag($0) } }
                    Text(preset.note).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("Server address", text: $baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField(preset.keyHelp, text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button(busy ? "Connecting…" : "Connect & list models", systemImage: "arrow.triangle.2.circlepath") { Task { await connect() } }
                        .disabled(busy || baseURL.isEmpty)
                    if !models.isEmpty { Text("\(models.count) models found").foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Add provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(models.isEmpty || name.isEmpty) }
            }
            .onChange(of: preset, initial: true) { _, new in name = new.name; baseURL = new.baseURL; models = []; error = nil }
        }
    }

    private func connect() async {
        busy = true; error = nil
        do { models = try await RemoteProvider.fetchModels(kind: preset.kind, baseURL: baseURL, apiKey: key.isEmpty ? nil : key) }
        catch { self.error = error.localizedDescription; models = [] }
        busy = false
    }

    private func save() {
        let record = ProviderRecord(name: name, kind: preset.kind, baseURL: baseURL)
        record.models = models
        if !key.isEmpty { Keychain.set(key, for: record.keyAccount) }
        context.insert(record)
        try? context.save()
        dismiss()
    }
}

struct ProviderDetail: View {
    @Environment(\.modelContext) private var context
    let provider: ProviderRecord
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: provider.kind.label)
                LabeledContent("Address", value: provider.baseURL)
                SecureField(provider.apiKey == nil ? "API key" : "API key (saved — enter to replace)", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { if !key.isEmpty { Keychain.set(key, for: provider.keyAccount); key = "" } }
            }
            Section("Models") {
                Button(busy ? "Refreshing…" : "Refresh model list", systemImage: "arrow.clockwise") {
                    Task {
                        busy = true
                        do { provider.models = try await RemoteProvider.fetchModels(kind: provider.kind, baseURL: provider.baseURL, apiKey: provider.apiKey); try? context.save() }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                ForEach(provider.models, id: \.self) { Text($0).font(.callout.monospaced()) }
            }
        }
        .navigationTitle(provider.name)
    }
}
