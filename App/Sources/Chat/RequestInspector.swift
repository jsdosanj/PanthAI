import SwiftUI

struct RequestRecord: Identifiable {
    let id = UUID()
    let date: Date
    let model: String
    let system: String
    let prompt: String
    let historyTurns: Int
    let sampling: SamplingSettings
    let toolCount: Int
    var firstTokenSeconds: Double?
    var totalSeconds: Double?
    var reply = ""

    var approxPromptTokens: Int { (system.count + prompt.count) / 4 }
    var approxReplyTokens: Int { reply.count / 4 }
    var tokensPerSecond: Double? {
        guard let total = totalSeconds, let first = firstTokenSeconds, total > first else { return nil }
        return Double(approxReplyTokens) / (total - first)
    }
}

/// Shows exactly what was sent to the model for each turn and how it performed.
struct RequestInspector: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatViewModel

    var body: some View {
        NavigationStack {
            List(model.requests.reversed()) { request in
                NavigationLink {
                    Form {
                        Section("Timing") {
                            LabeledContent("Model", value: request.model)
                            LabeledContent("First token", value: request.firstTokenSeconds.map { "\($0.formatted(.number.precision(.fractionLength(2)))) s" } ?? "—")
                            LabeledContent("Total", value: request.totalSeconds.map { "\($0.formatted(.number.precision(.fractionLength(2)))) s" } ?? "—")
                            LabeledContent("Speed", value: request.tokensPerSecond.map { "~\(Int($0)) tok/s" } ?? "—")
                            LabeledContent("Prompt size", value: "~\(request.approxPromptTokens) tokens + \(request.historyTurns) earlier turns")
                            LabeledContent("Tools offered", value: "\(request.toolCount)")
                        }
                        Section("Sampling") {
                            Text(request.sampling.isDefault ? "Model defaults" : (try? String(data: JSONEncoder().encode(request.sampling), encoding: .utf8)) ?? "")
                                .font(.callout.monospaced())
                        }
                        Section("System instructions") { Text(request.system).font(.caption.monospaced()).textSelection(.enabled) }
                        Section("Prompt") { Text(request.prompt).font(.caption.monospaced()).textSelection(.enabled) }
                        Section("Reply") { Text(request.reply).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    .navigationTitle(request.date.formatted(date: .omitted, time: .standard))
                } label: {
                    VStack(alignment: .leading) {
                        Text(request.prompt.prefix(80)).lineLimit(1)
                        Text("\(request.model) · \(request.totalSeconds.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "…") s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if model.requests.isEmpty { ContentUnavailableView("No requests yet", systemImage: "list.bullet.rectangle", description: Text("Send a message, then come back.")) } }
            .navigationTitle("Request inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
