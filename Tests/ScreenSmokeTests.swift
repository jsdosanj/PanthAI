import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import DosanjhAI

/// Builds each screen inside a real window, lays it out and saves a PNG. Catches crashes and empty screens
/// without needing the simulator's accessibility channel.
@MainActor
struct ScreenSmokeTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: ChatSessionRecord.self, WorkspaceRecord.self, ProviderRecord.self, MCPServerRecord.self, AgentRecord.self,
                           TaskRecord.self, PromptTemplate.self, SSHHostRecord.self, SSHKeyRecord.self, SnippetRecord.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func render<V: View>(_ name: String, @ViewBuilder _ view: () -> V) throws {
        let host = UIHostingController(rootView: view().modelContainer(try container()).frame(width: 1000, height: 1300))
        // A window with no scene draws nothing on current iPadOS, so attach it to the host app's scene.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 1300)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let dir = URL(filePath: "/tmp/dosanjhai-shots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try image.pngData()?.write(to: dir.appending(path: "\(name).png"))
        // A blank (all one colour) picture means nothing was drawn.
        let sample = try #require(image.cgImage)
        #expect(Self.hasContent(sample), "\(name) rendered a blank image")
    }

    @Test func rootShell() throws { try render("root") { RootShell() } }
    @Test func models() throws { try render("models") { NavigationStack { ModelsView(state: WindowState()) } } }
    @Test func hosts() throws { try render("hosts") { HostsView() } }
    @Test func pullRequests() throws { try render("pull-requests") { NavigationStack { PullRequestsView() } } }
    @Test func compare() throws { try render("compare") { NavigationStack { CompareView() } } }
    @Test func benchmark() throws { try render("benchmark") { NavigationStack { BenchmarkView() } } }
    @Test func evals() throws { try render("evals") { NavigationStack { EvalView() } } }
    @Test func fineTune() throws { try render("finetune") { NavigationStack { FineTuneView() } } }
    @Test func settings() throws { try render("settings") { SettingsView() } }
    @Test func networkActivity() throws { try render("network") { NavigationStack { NetworkActivityView() } } }
    @Test func keyManager() throws { try render("keys") { NavigationStack { KeyManagerView() } } }
    @Test func shortcutsHelp() throws { try render("shortcuts") { ShortcutsHelp() } }

    private static func hasContent(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        let first = (bytes[0], bytes[1], bytes[2])
        var differing = 0
        var i = 0
        while i + 3 < length { if (bytes[i], bytes[i + 1], bytes[i + 2]) != first { differing += 1; if differing > 500 { return true } }; i += 64 }
        return false
    }
}
