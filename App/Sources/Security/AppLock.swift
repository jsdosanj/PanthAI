import LocalAuthentication
import SwiftUI

/// Face ID / Touch ID / passcode lock, plus a privacy shield that hides content in the app switcher.
@MainActor @Observable
final class AppLock {
    static let shared = AppLock()

    var isLocked: Bool
    private var backgroundedAt: Date?
    private var authenticating = false

    static var enabled: Bool { UserDefaults.standard.bool(forKey: Prefs.appLock) }
    /// Seconds in the background before the lock returns. 0 = every time.
    static var graceSeconds: Double { UserDefaults.standard.object(forKey: Prefs.lockGrace) as? Double ?? 60 }

    private init() { isLocked = Self.enabled }

    func didEnterBackground() { backgroundedAt = .now }

    func didBecomeActive() {
        guard Self.enabled else { isLocked = false; return }
        if let left = backgroundedAt, Date().timeIntervalSince(left) >= Self.graceSeconds { isLocked = true }
        backgroundedAt = nil
        if isLocked { Task { await unlock() } }
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false   // no passcode set on this iPad, so there is nothing to ask for
            return
        }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock PanthAI")) == true { isLocked = false }
    }
}

/// Covers the window when the app is locked or leaving the screen, so the app switcher never shows your chats.
struct PrivacyShield: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @AppStorage(Prefs.hideInSwitcher) private var hideInSwitcher = true
    private let lock = AppLock.shared

    func body(content: Content) -> some View {
        content
            .blur(radius: lock.isLocked || (hideInSwitcher && phase != .active) ? 30 : 0)
            .overlay {
                if lock.isLocked {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.fill").font(.largeTitle)
                        Text("PanthAI is locked").font(.title2.weight(.semibold))
                        Button("Unlock", systemImage: "faceid") { Task { await lock.unlock() } }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    .padding(40)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                } else if hideInSwitcher && phase != .active {
                    Image(systemName: "sparkles").font(.system(size: 60)).foregroundStyle(.secondary)
                }
            }
            .allowsHitTesting(!lock.isLocked)
            .accessibilityHidden(lock.isLocked)   // VoiceOver must not read the chats behind the lock screen
            .onChange(of: phase) { _, new in
                if new == .background { lock.didEnterBackground() }
                if new == .active { lock.didBecomeActive() }
            }
            .task { if AppLock.enabled { await lock.unlock() } }
    }
}

extension View { func privacyShield() -> some View { modifier(PrivacyShield()) } }
