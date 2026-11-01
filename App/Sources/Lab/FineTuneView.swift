import SwiftUI
import UniformTypeIdentifiers

struct FineTuneView: View {
    private let trainer = LoRATrainer.shared
    @State private var model: CuratedModel?
    @State private var dataset: URL?
    @State private var name = "my-adapter"
    @State private var settings = LoRATrainer.Settings()
    @State private var importing = false

    private var candidates: [CuratedModel] {
        CuratedModels.everything.filter { ModelManager.shared.isDownloaded($0.id) && $0.weightsGB <= 4.5 && !$0.capabilities.contains(.ocr) }
    }

    var body: some View {
        Form {
            Section {
                Label("Experimental. Keep PanthAI open with the screen on. Training heats the iPad and works best on small models (up to about 4 GB).", systemImage: "flask")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Base model") {
                Picker("Model", selection: $model) {
                    Text("Choose…").tag(CuratedModel?.none)
                    ForEach(candidates) { Text($0.name).tag(CuratedModel?.some($0)) }
                }
                if candidates.isEmpty { Text("Download a small text model first (for example Qwen3 1.7B).").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Data") {
                Button(dataset?.lastPathComponent ?? "Choose a .jsonl file…", systemImage: "doc.text") { importing = true }
                Text("One example per line, like {\"text\": \"Q: … A: …\"}. At least 4 lines; 10% are held back to check progress.").font(.footnote).foregroundStyle(.secondary)
                TextField("Adapter name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Settings") {
                Stepper("Steps: \(settings.iterations)", value: $settings.iterations, in: 20...1000, step: 20)
                Stepper("Batch size: \(settings.batchSize)", value: $settings.batchSize, in: 1...4)
                Stepper("Layers tuned: \(settings.layers)", value: $settings.layers, in: 1...16)
                Stepper("Rank: \(settings.rank)", value: $settings.rank, in: 2...32, step: 2)
            }
            Section {
                if trainer.running {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { trainer.stop() }
                } else {
                    Button("Start training", systemImage: "play.fill") {
                        if let model, let dataset { Task { await trainer.train(model: model, dataset: dataset, adapterName: name, settings: settings) } }
                    }.disabled(model == nil || dataset == nil || name.isEmpty)
                }
                if let loss = trainer.lastLoss { LabeledContent("Loss", value: loss.formatted(.number.precision(.fractionLength(3)))) }
                ForEach(Array(trainer.log.suffix(12).enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
            } header: { Text("Training") } footer: {
                Text("When it finishes, the adapter is applied to that model automatically. Remove it from Models if you want the original behaviour back.")
            }
        }
        .navigationTitle("Fine-tune")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { if case .success(let url) = $0 { dataset = url } }
    }
}

extension CuratedModel: Hashable {
    static func == (lhs: CuratedModel, rhs: CuratedModel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
