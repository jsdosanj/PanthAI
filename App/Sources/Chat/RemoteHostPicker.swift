import SwiftData
import SwiftUI

/// Which of your machines the assistant may run commands on in this chat (each command still asks first).
struct RemoteHostPicker: View {
    let model: ChatViewModel
    @Query(sort: \SSHHostRecord.createdAt) private var hosts: [SSHHostRecord]

    var body: some View {
        if !hosts.isEmpty {
            Section {
                Picker("Machine", selection: Binding(get: { model.record.sshHostID }, set: { model.record.sshHostID = $0 })) {
                    Text("None").tag(UUID?.none)
                    ForEach(hosts) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            } header: { Text("Remote machine") } footer: { Text("Lets the assistant run commands and read files there. Every command asks for approval, and destructive ones are refused.") }
        }
    }
}
