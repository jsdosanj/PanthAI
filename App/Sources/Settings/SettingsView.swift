import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.displayName) private var displayName = ""
    @AppStorage(Prefs.about) private var about = ""
    @AppStorage(Prefs.style) private var style = ResponseStyle.balanced.rawValue
    @AppStorage(Prefs.extra) private var extra = ""
    @AppStorage(Prefs.useTemperature) private var useTemperature = false
    @AppStorage(Prefs.temperature) private var temperature = 0.7
    @AppStorage(Prefs.returnSends) private var returnSends = true
    @AppStorage(Prefs.focusOnLaunch) private var focusOnLaunch = true
    @AppStorage(Prefs.siriContext) private var siriContext = true
    @AppStorage(Prefs.webSearch) private var webSearch = true
    @AppStorage(Prefs.codeExecution) private var codeExecution = true
    @AppStorage(Prefs.memory) private var memory = true
    @AppStorage(Prefs.defaultNetwork) private var defaultNetwork = NetworkMode.full.rawValue
    @State private var braveKey = Keychain.get(WebSearchTool.braveKeyAccount) ?? ""
    @State private var githubToken = ""
    @State private var hasToken = Keychain.get(GitHubClient.tokenAccount) != nil

    private func saveToken() {
        guard !githubToken.isEmpty else { return }
        hasToken = Keychain.set(githubToken, for: GitHubClient.tokenAccount)
        githubToken = ""
    }

    @ViewBuilder private var personalizeSection: some View {
                Section {
                    TextField("Your name", text: $displayName)
                    TextField("About you (job, interests, reading level…)", text: $about, axis: .vertical)
                        .lineLimit(2...5)
                    Picker("Style", selection: $style) {
                        ForEach(ResponseStyle.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    TextField("Custom instructions", text: $extra, axis: .vertical).lineLimit(3...8)
                    Toggle("Set creativity manually", isOn: $useTemperature)
                    if useTemperature {
                        Slider(value: $temperature, in: 0...2, step: 0.1) {
                            Text("Creativity")
                        } minimumValueLabel: { Text("Precise") } maximumValueLabel: { Text("Creative") }
                        Text("Temperature \(temperature.formatted(.number.precision(.fractionLength(1))))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Personalize responses")
                } footer: {
                    Text("These are sent to the model you're chatting with, as instructions. They stay on this iPad.")
                }
    }

    @ViewBuilder private var keyboardSection: some View {
                Section {
                    Toggle("Show keyboard when DosanjhAI opens", isOn: $focusOnLaunch)
                    Toggle("Return sends message", isOn: $returnSends)
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text(returnSends
                         ? "Return sends. Shift-Return adds a new line."
                         : "Return adds a new line. Command-Return sends.")
                }
    }

    @ViewBuilder private var notificationsSection: some View {
                Section {
                    ForEach(NotificationKind.allCases) { kind in
                        Toggle(isOn: Binding(get: { kind.enabled }, set: { UserDefaults.standard.set($0, forKey: kind.prefKey) })) {
                            VStack(alignment: .leading) { Text(kind.label); Text(kind.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Button("Allow notifications…") { Task { await Notifier.authorizeIfNeeded() } }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("If you turned notifications off in iPadOS Settings, re-enable them there. Notifications are made on this iPad; nothing goes through a server.")
                }
    }

    @ViewBuilder private var toolsSection: some View {
                Section {
                    Toggle("Web search", isOn: $webSearch)
                    Toggle("Run code (JavaScript sandbox)", isOn: $codeExecution)
                    Toggle("Memory", isOn: $memory)
                    NavigationLink("View and edit memory") { MemoryEditor() }
                    Picker("Network for new chats", selection: $defaultNetwork) {
                        ForEach(NetworkMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    SecureField("Brave Search API key (optional)", text: $braveKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { if braveKey.isEmpty { Keychain.delete(WebSearchTool.braveKeyAccount) } else { Keychain.set(braveKey, for: WebSearchTool.braveKeyAccount) } }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("Network defaults to full access. Change it for a single chat in its details panel, including an allow-list of sites. Without a Brave key, search uses DuckDuckGo. Files the assistant creates appear in the Files app under On My iPad › DosanjhAI.")
                }
    }

    @ViewBuilder private var githubSection: some View {
                Section {
                    SecureField("GitHub personal access token", text: $githubToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { saveToken() }
                    Button("Save token") { saveToken() }
                    if hasToken {
                        Button("Remove token", role: .destructive) {
                            Keychain.delete(GitHubClient.tokenAccount); githubToken = ""; hasToken = false
                        }
                    }
                } header: {
                    Text("GitHub")
                } footer: {
                    Text(hasToken ? "Token saved in your Keychain (syncs via iCloud Keychain). Used only to talk to GitHub."
                                  : "Create a fine-grained token with Contents (read & write) and Pull requests access. Stored in your Keychain.")
                }
    }

    @ViewBuilder private var siriSection: some View {
                Section {
                    Toggle("Let Siri and Spotlight use my chats", isOn: $siriContext)
                        .onChange(of: siriContext) { _, on in if !on { ChatIndexer.removeAll() } }
                } header: {
                    Text("Siri & Shortcuts")
                } footer: {
                    Text("Say \"Ask DosanjhAI\", or \"Open [chat] in DosanjhAI\". Siri can also see which chat is on screen and search your chats. Titles and recent messages are added to this iPad's on-device search index; nothing leaves the iPad. Turning this off removes them.")
                }
    }

    @ViewBuilder private var privacyNote: some View {
                Section("Privacy") {
                    Text("DosanjhAI has no accounts and collects no data. The advanced Apple model runs on Apple's Private Cloud Compute, so your prompts leave the iPad for Apple's servers when you choose it; Apple states it doesn't store them.")
                        .font(.footnote)
                }
    }

    private func page<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Form { content() }.navigationTitle(title)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { page("General") { personalizeSection; keyboardSection; siriSection } } label: { Label("General", systemImage: "slider.horizontal.3") }
                    NavigationLink { page("Models") { ProvidersSection() } } label: { Label("Model providers", systemImage: "cloud") }
                    NavigationLink { page("Assistants") { AgentsSection(); TemplatesSection(); TasksSection() } } label: { Label("Agents, templates and tasks", systemImage: "person.2") }
                    NavigationLink { page("Connectors") { ConnectorsSection(); githubSection } } label: { Label("Connectors and GitHub", systemImage: "puzzlepiece.extension") }
                    NavigationLink { page("Tools") { toolsSection } } label: { Label("Tools and memory", systemImage: "wrench.and.screwdriver") }
                    NavigationLink { page("Notifications") { notificationsSection } } label: { Label("Notifications", systemImage: "bell") }
                }
                Section {
                    NavigationLink { page("Security and privacy") { SecuritySection(); PrivacyNetworkSection(); privacyNote } } label: { Label("Security and privacy", systemImage: "lock.shield") }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
