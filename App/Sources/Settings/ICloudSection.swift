import SwiftUI

/// Optional sync through the user's own iCloud account. Off by default.
struct ICloudSection: View {
    @AppStorage(Prefs.iCloudSync) private var on = false
    @AppStorage(Prefs.offline) private var offline = false
    private var status = SyncStatus.shared

    private var signedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    var body: some View {
        Section {
            Toggle("Sync with iCloud", isOn: $on)
            if on {
                if !signedIn {
                    Label("Sign in to iCloud in iPadOS Settings to sync.", systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                } else if offline {
                    Label("Offline mode is on, so sync is paused.", systemImage: "icloud.slash").foregroundStyle(.orange)
                } else if !AppData.isSyncing {
                    Label("Close and reopen PanthAI to start syncing.", systemImage: "arrow.clockwise.icloud").foregroundStyle(.orange)
                } else {
                    LabeledContent("Last synced") { Text(status.lastSynced.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Waiting…") }
                    if let error = status.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                }
            } else if AppData.isSyncing {
                Label("Close and reopen PanthAI to stop syncing.", systemImage: "arrow.clockwise.icloud").foregroundStyle(.orange)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Your data goes to your own private iCloud, which only you and your devices can read; it isn't sent to PanthAI or anyone else. iCloud sync is handled by iPadOS, so it isn't listed in the network activity log. Turning sync off stops it, but copies already in iCloud stay until you delete them in iPadOS Settings › iCloud › Manage Storage.")
        }
        Section {
            Label("Chats and code sessions", systemImage: "checkmark.circle")
            Label("Agents, prompt templates and tasks", systemImage: "checkmark.circle")
            Label("Model providers, connectors and SSH hosts (names and addresses)", systemImage: "checkmark.circle")
            Label("Repositories you've loaded (the list; files stay put)", systemImage: "checkmark.circle")
            Label("Settings and personalization", systemImage: "checkmark.circle")
            Label("API tokens, through iCloud Keychain (end-to-end encrypted)", systemImage: "checkmark.circle")
        } header: {
            Text("Syncs")
        }
        Section {
            Label("Downloaded models", systemImage: "ipad")
            Label("Knowledge (documents and photos you added)", systemImage: "ipad")
            Label("Repository files", systemImage: "ipad")
            Label("SSH keys and passwords", systemImage: "ipad")
            Label("App lock, offline mode and other security switches", systemImage: "ipad")
        } header: {
            Text("Stays on each iPad")
        } footer: {
            Text("A chat that used a repository or SSH key from another iPad opens without it; load the repository or add the key here to continue.")
        }
    }
}
