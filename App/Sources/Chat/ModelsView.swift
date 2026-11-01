import SwiftUI

struct ModelsView: View {
    @Bindable var state: WindowState
    @Environment(\.modelContext) private var context
    private let device = DeviceProfile.current
    private let manager = ModelManager.shared
    @State private var showAdd = false
    @State private var refresh = 0

    private func summary(for model: CuratedModel) -> String {
        let size = model.weightsGB.formatted(.number.precision(.fractionLength(1)))
        return "\(size) GB · " + model.capabilities.map(\.rawValue).joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("This iPad: \(device.physicalMemoryGB.formatted(.number.precision(.fractionLength(0)))) GB memory · about \(device.modelBudgetGB.formatted(.number.precision(.fractionLength(1)))) GB available to a model")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(CuratedModels.families, id: \.self) { family in
                    Section(family) {
                        ForEach(CuratedModels.everything.filter { $0.family == family }) { row($0) }
                    }
                }
            }
            .navigationTitle("Models")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add model", systemImage: "plus") { showAdd = true } } }
            .sheet(isPresented: $showAdd) { AddModelSheet { manager.refreshCatalog(); refresh += 1 } }
            .id(refresh)
        }
    }

    @ViewBuilder private func row(_ model: CuratedModel) -> some View {
        let modelState = manager.state(of: model.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.name).font(.headline)
                Spacer()
                CompatibilityBadge(compatibility: model.compatibility)
            }
            Text(summary(for: model)).font(.subheadline).foregroundStyle(.secondary)
            Text(model.note).font(.footnote)
            Text("License: \(model.license)").font(.caption).foregroundStyle(.secondary)
            if model.family == "Your models" { Button("Remove", role: .destructive) { CustomModels.remove(model.id); refresh += 1 }.font(.caption).buttonStyle(.borderless) }
            switch model.runtimeReady ? modelState : .failed("Not yet supported by the on-device runtime.") {
            case .notDownloaded:
                Button("Download & use", systemImage: "arrow.down.circle") { manager.load(model) }
                    .buttonStyle(.bordered)
                    .disabled(model.compatibility == .wontFit)
                if model.compatibility == .wontFit {
                    Text("Needs more memory than this iPad has.").font(.caption).foregroundStyle(.secondary)
                }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading… \(Int(fraction * 100))%").font(.caption) }
            case .ready:
                HStack {
                    Button("Chat", systemImage: "bubble.left") {
                        state.newChat(in: context, choice: .mlx(model.id))
                    }
                    Button("Code session", systemImage: "chevron.left.forwardslash.chevron.right") {
                        state.newChat(in: context, choice: .mlx(model.id), kind: .code)
                    }
                }.buttonStyle(.bordered).controlSize(.regular)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(model.runtimeReady ? .red : .secondary)
                if model.runtimeReady { Button("Retry", systemImage: "arrow.clockwise") { manager.load(model) } }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
