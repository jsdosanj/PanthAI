import SwiftUI

struct PrivacyNetworkSection: View {
    @AppStorage(Prefs.offline) private var offline = false
    @AppStorage(Prefs.offlineAllowLocal) private var allowLocal = true

    var body: some View {
        Section {
            Toggle("Offline mode", isOn: $offline)
            if offline { Toggle("Still allow my own network and Tailscale", isOn: $allowLocal) }
            NavigationLink("Network activity") { NetworkActivityView() }
        } header: {
            Text("Privacy & network")
        } footer: {
            Text("Offline mode blocks every request the app makes: model downloads, web search, GitHub, connectors and cloud models. On-device models keep working. Network activity lists each request that leaves this iPad.")
        }
    }
}

struct NetworkActivityView: View {
    private let log = NetLog.shared
    private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    var body: some View {
        List {
            Section {
                LabeledContent("Sent", value: size(log.totalOut))
                LabeledContent("Received", value: size(log.totalIn))
                Text("Only the address and size of each request are recorded, never its contents or query strings, and nothing is saved after you close the app. Apple's Private Cloud Compute model and sign-in sheets are handled by iPadOS and don't appear here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Requests") {
                if log.entries.isEmpty { Text("Nothing has left this iPad since the app opened.").foregroundStyle(.secondary) }
                ForEach(log.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.purpose).font(.callout.weight(.semibold))
                            Spacer()
                            Text(entry.status).font(.caption.monospaced()).foregroundStyle(entry.status == "Blocked" ? Color.orange : .secondary)
                        }
                        Text("\(entry.method) \(entry.host)\(entry.path)").font(.caption.monospaced()).lineLimit(1)
                        Text("\(entry.date.formatted(date: .omitted, time: .standard)) · ↑ \(size(entry.bytesOut)) ↓ \(size(entry.bytesIn))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Network activity")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Clear", role: .destructive) { log.clear() } } }
    }
}
