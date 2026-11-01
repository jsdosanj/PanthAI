import SwiftData
import SwiftUI

struct BenchmarkView: View {
    @Query(sort: \ProviderRecord.createdAt) private var providers: [ProviderRecord]
    @State private var selection: Set<ProviderChoice> = [.apple(.onDevice)]
    @State private var size = 1
    @State private var repeats = 2
    @State private var rows: [Row] = []
    @State private var running = false
    @State private var csv: URL?

    struct Row: Identifiable {
        let id = UUID()
        let choice: ProviderChoice
        let run: Int
        let result: Generator.Result
    }

    private let prompts = [
        "Explain what a hash table is in two sentences.",
        "Write a Swift function that merges two sorted arrays, then explain its time complexity and edge cases.",
        String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 120) + "\n\nSummarise the text above in one sentence.",
    ]

    var body: some View {
        Form {
            Section("Models") { ModelMultiPicker(options: ModelPool.options(providers: providers), selection: $selection) }
            Section {
                Picker("Prompt size", selection: $size) { Text("Short").tag(0); Text("Medium").tag(1); Text("Long (prefill)").tag(2) }
                Stepper("Runs per model: \(repeats)", value: $repeats, in: 1...5)
                Button(running ? "Running…" : "Run benchmark", systemImage: "gauge.with.dots.needle.67percent") { Task { await run() } }.disabled(running || selection.isEmpty)
            } footer: { Text("Models run one after another. Speeds are estimated from output length (about 4 characters per token). Peak memory is this app's footprint during the run. A hot iPad slows down, so thermal state is recorded.") }
            if !rows.isEmpty {
                Section("Results") {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.choice.label) · run \(row.run)").font(.callout.weight(.semibold))
                            if let error = row.result.error { Text(error).font(.caption).foregroundStyle(.red) } else {
                                Text("first token \(fmt(row.result.firstTokenSeconds)) s · \(row.result.tokensPerSecond.map { "\(Int($0))" } ?? "—") tok/s · total \(fmt(row.result.totalSeconds)) s")
                                    .font(.caption.monospacedDigit())
                                Text("peak \(fmt(row.result.peakFootprintGB)) GB · load \(fmt(row.result.loadSeconds)) s · thermal \(row.result.thermal.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let csv { ShareLink("Export CSV", item: csv) }
                }
            }
        }
        .navigationTitle("Benchmark")
    }

    private func fmt(_ v: Double?) -> String { v.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—" }

    private func run() async {
        running = true; rows = []; csv = nil
        for choice in ProviderModelOrder.sorted(selection) {
            for i in 1...repeats {
                let result = await Generator.run(choice, prompt: prompts[size], sampling: SamplingSettings(temperature: 0, maxTokens: 200))
                rows.append(Row(choice: choice, run: i, result: result))
            }
        }
        csv = CSV.file(named: "benchmark.csv", rows: [["model", "run", "first_token_s", "tokens_per_s", "total_s", "peak_gb", "load_s", "thermal", "error"]] + rows.map {
            [$0.choice.label, "\($0.run)", fmt($0.result.firstTokenSeconds), $0.result.tokensPerSecond.map { String(Int($0)) } ?? "", fmt($0.result.totalSeconds),
             fmt($0.result.peakFootprintGB), fmt($0.result.loadSeconds), $0.result.thermal.label, $0.result.error ?? ""]
        })
        running = false
    }
}

enum ProviderModelOrder {
    static func sorted(_ set: Set<ProviderChoice>) -> [ProviderChoice] { set.sorted { $0.key < $1.key } }
}
