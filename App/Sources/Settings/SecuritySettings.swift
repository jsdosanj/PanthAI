import SwiftUI

struct SecuritySection: View {
    @AppStorage(Prefs.appLock) private var appLock = false
    @AppStorage(Prefs.lockGrace) private var grace = 60.0
    @AppStorage(Prefs.hideInSwitcher) private var hideInSwitcher = true
    @AppStorage(Prefs.protectKeys) private var protectKeys = true
    @AppStorage(Prefs.maxProtection) private var maxProtection = false
    @State private var confirmErase = false

    var body: some View {
        Section {
            Toggle("Lock with Face ID or passcode", isOn: $appLock)
            if appLock {
                Picker("Lock after", selection: $grace) {
                    Text("Immediately").tag(0.0); Text("1 minute").tag(60.0); Text("5 minutes").tag(300.0); Text("15 minutes").tag(900.0)
                }
            }
            Toggle("Hide content in the app switcher", isOn: $hideInSwitcher)
            Toggle("Require Face ID for SSH keys", isOn: $protectKeys)
            Toggle("Maximum file protection", isOn: $maxProtection)
                .onChange(of: maxProtection) { _, _ in DataProtection.apply() }
            Button("Erase all DosanjhAI data…", role: .destructive) { confirmErase = true }
        } header: {
            Text("Security")
        } footer: {
            Text("SSH keys and passwords never leave this iPad and are stored in the Keychain. Maximum file protection encrypts chats, memory and repos whenever the iPad is locked; Shortcuts automations can't run then. New SSH keys use the Face ID setting at the moment you create them.")
        }
        .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase All Data", role: .destructive) { SecurityWipe.eraseEverything() }
        } message: { Text("Deletes all chats, memory, repos, downloaded models, keys, tokens and settings from this iPad. This can't be undone.") }
    }
}

enum SecurityWipe {
    @MainActor static func eraseEverything() {
        Keychain.deleteAll()
        let manager = FileManager.default
        for root in [URL.applicationSupportDirectory, URL.documentsDirectory, URL.cachesDirectory] {
            for item in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] { try? manager.removeItem(at: item) }
        }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        ChatIndexer.removeAll()
        exit(0)   // the chat database was just deleted; restart clean
    }
}
