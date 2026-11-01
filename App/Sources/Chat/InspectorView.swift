import SwiftUI

/// Right-hand details panel: model, memory, generation stats.
struct InspectorView: View {
    let model: ChatViewModel
    private let device = DeviceProfile.current
    @State private var showRequests = false

    var body: some View {
        Form {
            if model.kind == .code { WorkspaceSection(model: model) }
            Section {
                Picker("Network", selection: Binding(get: { model.record.network }, set: { model.record.network = $0 })) {
                    ForEach(NetworkMode.allCases) { Text($0.label).tag($0) }
                }
                if model.record.network == .custom {
                    TextField("Allowed sites, comma separated", text: Binding(
                        get: { model.record.allowedHosts.joined(separator: ", ") },
                        set: { model.record.allowedHosts = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } header: { Text("Network access") } footer: { Text("Applies to this chat only. Set the default for new chats in Settings.") }
            AgentPicker(model: model)
            RemoteHostPicker(model: model)
            ConnectorToggles(model: model)
            if model.kind == .code {
                Section("Agent") {
                    Picker("Mode", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                        ForEach(PermissionMode.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                    Button("Compact conversation", systemImage: "arrow.down.right.and.arrow.up.left") { model.compact() }
                        .disabled(model.turns.count <= 6 || model.isStreaming)
                }
            }
            Section {
                SamplingControls(model: model)
                Button("Inspect requests…", systemImage: "list.bullet.rectangle") { showRequests = true }
            } header: { Text("Generation") }
            Section {
                TextField("JSON Schema (optional)", text: Bindable(model.record).schemaText, axis: .vertical)
                    .font(.callout.monospaced()).lineLimit(3...10).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Structured output") } footer: { Text("When set, replies must be JSON matching the schema. The assistant is asked to fix invalid replies automatically.") }
            BranchesSection(record: model.record)
            Section("Model") {
                LabeledContent("Engine", value: model.choice.label)
                if case .mlx(let repo) = model.choice, let m = CuratedModels.everything.first(where: { $0.id == repo }) {
                    LabeledContent("Size", value: "\(m.weightsGB.formatted(.number.precision(.fractionLength(1)))) GB")
                    LabeledContent("License", value: m.license)
                    HStack { Text("Fit"); Spacer(); CompatibilityBadge(compatibility: m.compatibility) }
                }
            }
            Section("This iPad") {
                LabeledContent("Memory", value: "\(device.physicalMemoryGB.formatted(.number.precision(.fractionLength(0)))) GB")
                LabeledContent("Model budget", value: "\(device.modelBudgetGB.formatted(.number.precision(.fractionLength(1)))) GB")
            }
            Section("Conversation") {
                LabeledContent("Type", value: model.kind == .code ? "Code session" : "Chat")
                LabeledContent("Messages", value: "\(model.turns.count)")
                LabeledContent("Context", value: "~\(model.estimatedContextTokens.formatted()) tokens")
                if let tps = model.tokensPerSecond {
                    LabeledContent("Speed", value: "~\(Int(tps)) tok/s")
                }
            }
        }
        .navigationTitle("Details")
        .sheet(isPresented: $showRequests) { RequestInspector(model: model) }
    }
}
