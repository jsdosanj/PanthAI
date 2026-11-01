import SwiftUI

@main
struct ipadAIApp: App {
    var body: some Scene {
        // Each window gets its own independent chat (multi-window / Stage Manager).
        WindowGroup {
            TabView {
                Tab("Chat", systemImage: "bubble.left.and.bubble.right") { ChatView() }
                Tab("Models", systemImage: "cpu") { ModelsView() }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
    }
}
