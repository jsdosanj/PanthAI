import SwiftData
import SwiftUI

/// Per-chat switches for which connectors the assistant may use.
struct ConnectorToggles: View {
    let model: ChatViewModel
    @Query(sort: \MCPServerRecord.createdAt) private var servers: [MCPServerRecord]

    var body: some View {
        if !servers.isEmpty {
            Section {
                ForEach(servers) { server in
                    Toggle(server.name, isOn: Binding(
                        get: { model.record.enabledConnectors.contains(server.id) },
                        set: { on in
                            var ids = model.record.enabledConnectors
                            if on { ids.append(server.id) } else { ids.removeAll { $0 == server.id } }
                            model.record.enabledConnectors = ids
                        }))
                }
            } header: { Text("Connectors") } footer: { Text("Each tool call still asks for your approval.") }
        }
    }
}
