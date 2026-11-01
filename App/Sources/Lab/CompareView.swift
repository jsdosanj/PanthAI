import SwiftData
import SwiftUI

/// One prompt, several models, side by side, with an optional judge model to score them.
struct CompareView: View {
    @Query(sort: \ProviderRecord.createdAt) private var providers: [ProviderRecord]
    @State private var prompt = ""
    @State private var selection: Set<ProviderChoice> = [.apple(.onDevice)]
    @State private var judge: ProviderChoice?
    @State private var outputs: [ProviderChoice: Generator.Result] = [:]
    @State private var scores: [ProviderChoice: Int] = [:]
    @State private var running = false

    private var order: [ProviderChoice] { ProviderModelOrder.sorted(selection) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Prompt to send to every model", text: $prompt, axis: .vertical)
                    .lineLimit(2...8).textFieldStyle(.roundedBorder)
                DisclosureGroup("Models (\(selection.count) selected)") {
                    ModelMultiPicker(options: ModelPool.options(providers: providers), selection: $selection)
                }
                Picker("Judge", selection: $judge) {
                    Text("No judge").tag(ProviderChoice?.none)
                    ForEach(ModelPool.options(providers: providers), id: \.self) { Text($0.label).tag(ProviderChoice?.some($0)) }
                }
                Button(running ? "Running…" : "Compare", systemImage: "rectangle.split.2x1") { Task { await run() } }
                    .buttonStyle(.borderedProminent).disabled(running || prompt.isEmpty || selection.isEmpty)
                LazyVGrid(columns: [.init(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(order, id: \.self) { choice in card(choice) }
                }
            }
            .padding()
        }
        .navigationTitle("Compare")
    }

    @ViewBuilder private func card(_ choice: ProviderChoice) -> some View {
        let result = outputs[choice]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(choice.label).font(.headline)
                Spacer()
                if let score = scores[choice] { Label("\(score)/10", systemImage: "star.fill").foregroundStyle(.orange).font(.subheadline.weight(.semibold)) }
            }
            if let result {
                Text("first token \(result.firstTokenSeconds.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—") s · \(result.tokensPerSecond.map { "\(Int($0)) tok/s" } ?? "—") · \(result.totalSeconds.formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let error = result.error { Text(error).foregroundStyle(.red).font(.callout) }
                else { MarkdownText(text: result.text) }
            } else { Text("Waiting…").foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    private func run() async {
        running = true; outputs = [:]; scores = [:]
        for choice in order {
            outputs[choice] = Generator.Result()
            let final = await Generator.run(choice, prompt: prompt) { partial in outputs[choice]?.text = partial }
            outputs[choice] = final
        }
        if let judge { await score(with: judge) }
        running = false
    }

    private func score(with judge: ProviderChoice) async {
        let answers = order.enumerated().map { "Answer \($0.offset + 1):\n\(outputs[$0.element]?.text ?? "")" }.joined(separator: "\n\n")
        let ask = "You are a strict grader. Question:\n\(prompt)\n\n\(answers)\n\nScore each answer from 1 to 10 for correctness and usefulness. Reply with ONLY JSON: {\"scores\": [n, n, ...]} in answer order."
        let reply = await Generator.run(judge, prompt: ask, sampling: SamplingSettings(temperature: 0))
        guard let json = SchemaValidator.extractJSON(from: reply.text), let list = json["scores"]?.array else { return }
        for (i, value) in list.enumerated() where i < order.count { if let n = value.int { scores[order[i]] = min(max(n, 1), 10) } }
    }
}
