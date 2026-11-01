import SwiftData
import SwiftUI

struct TerminalWindow: View {
    let id: UUID?
    @Query private var hosts: [SSHHostRecord]

    var body: some View {
        NavigationStack {
            if let host = hosts.first(where: { $0.id == id }) { TerminalScreen(host: host, hosts: hosts) }
            else { ContentUnavailableView("Machine not found", systemImage: "server.rack") }
        }
    }
}
