import SwiftUI

/// Raw JSON-RPC traffic for one connector, plus a way to call its tools by hand.
struct MCPInspectorView: View {
    let server: MCPServerRecord
    private let hub = MCPHub.shared
    @State private var toolName = ""
    @State private var argsText = "{}"
    @State private var output = ""
    @State private var running = false

    var body: some View {
        Form {
            Section("Call a tool") {
                Picker("Tool", selection: $toolName) {
                    Text("Choose…").tag("")
                    ForEach(hub.tools[server.id] ?? []) { Text($0.name).tag($0.name) }
                }
                if let tool = hub.tools[server.id]?.first(where: { $0.name == toolName }) {
                    Text(tool.parameterList.isEmpty ? "No arguments" : tool.parameterList).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                TextField("Arguments as JSON", text: $argsText, axis: .vertical).font(.callout.monospaced()).lineLimit(2...8)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(running ? "Calling…" : "Call", systemImage: "play.fill") {
                    guard let args = JSONValue.parse(argsText)?.object else { output = "Arguments must be a JSON object."; return }
                    Task { running = true; output = await hub.callManually(server, tool: toolName, arguments: args); running = false }
                }.disabled(toolName.isEmpty || running)
                if !output.isEmpty { Text(output).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Section("Traffic") {
                let entries = (hub.traffic[server.id] ?? []).reversed()
                if entries.isEmpty { Text("No messages yet. Check the connection first.").foregroundStyle(.secondary) }
                ForEach(Array(entries)) { entry in
                    DisclosureGroup {
                        Text(entry.body).font(.caption.monospaced()).textSelection(.enabled)
                    } label: {
                        HStack {
                            Image(systemName: entry.outgoing ? "arrow.up.right" : "arrow.down.left").foregroundStyle(entry.outgoing ? Color.accentColor : .green)
                            Text(entry.summary).font(.callout.monospaced())
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("\(server.name) inspector")
    }
}
