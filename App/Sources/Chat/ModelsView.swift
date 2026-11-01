import SwiftUI

struct ModelsView: View {
    private let device = DeviceProfile.current

    private func summary(for model: CuratedModel) -> String {
        let size = model.weightsGB.formatted(.number.precision(.fractionLength(1)))
        return "\(size) GB · " + model.capabilities.map(\.rawValue).joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("This iPad: \(device.physicalMemoryGB, specifier: "%.0f") GB memory · about \(device.modelBudgetGB, specifier: "%.1f") GB available to a model")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(CuratedModels.all) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(model.name).font(.headline)
                            Spacer()
                            CompatibilityBadge(compatibility: model.compatibility)
                        }
                        Text(summary(for: model))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(model.note).font(.footnote)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("Models")
        }
    }
}
