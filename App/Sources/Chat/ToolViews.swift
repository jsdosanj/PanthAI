import SwiftUI
import WebKit

struct DiffView: View {
    let change: FileChange
    var body: some View {
        let lines = LineDiff.compute(before: change.before, after: change.after)
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: 6) {
                        Text(line.kind == .added ? "+" : (line.kind == .removed ? "−" : " ")).foregroundStyle(.secondary)
                        Text(line.text.isEmpty ? " " : line.text)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.kind == .added ? Color.green.opacity(0.18) : (line.kind == .removed ? Color.red.opacity(0.18) : .clear))
                }
            }
            .frame(minWidth: 300, alignment: .leading)
        }
        .frame(maxHeight: 260)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A tool call shown inline in the transcript.
struct ToolTurnCard: View {
    let turn: ChatTurn
    let model: ChatViewModel
    @State private var expanded = false

    private var icon: String {
        switch turn.toolStatus ?? .pending {
        case .pending, .running: "ellipsis.circle"
        case .done: "checkmark.circle.fill"
        case .denied: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .undone: "arrow.uturn.backward.circle"
        }
    }

    private var tint: Color {
        switch turn.toolStatus ?? .pending {
        case .done: .green
        case .denied, .failed: .orange
        default: .secondary
        }
    }

    private var summary: String {
        guard let raw = turn.toolArgs, let json = JSONValue.parse(raw) else { return turn.toolName ?? "tool" }
        let args = json["arguments"]?.object ?? [:]
        let detail = args["path"]?.string ?? args["url"]?.string ?? args["query"]?.string ?? args["folder"]?.string ?? ""
        return "\(turn.toolName ?? "tool") \(detail)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    if turn.toolStatus == .running { ProgressView().controlSize(.small) } else { Image(systemName: icon).foregroundStyle(tint) }
                    Text(summary).font(.callout.monospaced()).lineLimit(1)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if let path = turn.changePath, let after = turn.changeAfter {
                DiffView(change: FileChange(path: path, before: turn.changeBefore, after: after))
                if turn.toolStatus == .done {
                    Button("Undo this change", systemImage: "arrow.uturn.backward") { model.undo(turnID: turn.id) }
                        .font(.caption).buttonStyle(.bordered)
                }
            }
            if expanded {
                Text(turn.text.isEmpty ? "(no output)" : turn.text)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
    }
}

/// A tool is asking permission. Presented as a sheet so the system draws it and the decision can't be missed.
struct ApprovalSheet: View {
    let approval: ChatViewModel.PendingApproval
    let model: ChatViewModel

    private var riskText: String {
        switch approval.risk {
        case .write: "Edits a file in your repo. You can undo it."
        case .network: "Makes a network request."
        case .networkWrite: "Sends data over the network."
        case .remote: "Changes something outside this iPad."
        case .execute: "Runs code in a sandbox with no network or file access."
        case .read: "Reads data."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if approval.tainted {
                    Section { Label("This chat has read content from the web, a connector or a remote machine. That content can contain hidden instructions, so check this request is something you asked for.", systemImage: "exclamationmark.shield.fill").font(.footnote).foregroundStyle(.orange) }
                }
                Section {
                    Text(riskText)
                    Text(approval.summary).font(.callout.monospaced()).textSelection(.enabled)
                }
                if let change = approval.change {
                    Section("Changes") { DiffView(change: change).listRowInsets(.init()) }
                }
                Section {
                    Button("Allow") { model.resolveApproval(.allow) }.buttonStyle(.borderedProminent)
                    Button("Always allow \(approval.toolName) this session") { model.resolveApproval(.allowAlways) }
                    Button("Deny", role: .destructive) { model.resolveApproval(.deny) }
                }
            }
            .navigationTitle("Allow \(approval.toolName)?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}

/// Offline preview for HTML/SVG the model writes. Network loads are blocked; scripts run in the page only.
struct ArtifactPreview: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.isOpaque = false
        let rules = """
        [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","raw","media","svg-document","fetch","websocket","ping","popup"]},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-network", encodedContentRuleList: rules) { list, _ in
            if let list { web.configuration.userContentController.add(list) }
            // Inline data: URLs are not blocked, so images/CSS embedded in the page still work.
            web.loadHTMLString(html, baseURL: nil)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
