import SwiftUI

struct ChatView: View {
    @State private var model = ChatViewModel()
    private let status = AppleIntelligenceStatus.current

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if case .unavailable(let reason) = status {
                    ContentUnavailableView("Apple Intelligence unavailable", systemImage: "sparkles", description: Text(reason))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(model.turns) { turn in
                                    Text(turn.text.isEmpty ? "…" : turn.text)
                                        .textSelection(.enabled)
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
                                        .background(turn.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1),
                                                    in: RoundedRectangle(cornerRadius: 14))
                                        .id(turn.id)
                                        .accessibilityLabel("\(turn.role.rawValue): \(turn.text)")
                                }
                            }
                            .padding()
                        }
                        .onChange(of: model.turns.last?.text) {
                            if let id = model.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                    if let error = model.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                    }
                    HStack(alignment: .bottom) {
                        TextField("Message", text: $model.input, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.send() }
                        Button(model.isStreaming ? "Stop" : "Send", systemImage: model.isStreaming ? "stop.fill" : "arrow.up") {
                            model.isStreaming ? model.stop() : model.send()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle(model.providerName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
