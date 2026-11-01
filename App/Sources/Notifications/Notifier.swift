import SwiftUI
import UserNotifications

enum NotificationKind: String, CaseIterable, Identifiable {
    case reply, permission, research, project
    var id: String { rawValue }
    var prefKey: String { "notify." + rawValue }
    var label: String {
        switch self {
        case .reply: "Replies"
        case .permission: "Permission requests"
        case .research: "Research complete"
        case .project: "Code and project updates"
        }
    }
    var detail: String {
        switch self {
        case .reply: "When a reply finishes while you're in another app."
        case .permission: "When code or a connector needs your OK. Tap Allow or Deny."
        case .research: "When a /research run finishes."
        case .project: "When changes are pushed, a pull request is opened, or a repo finishes loading."
        }
    }
    var enabled: Bool { UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true }
}

/// Local notifications only; nothing is sent through a server.
enum Notifier {
    static let permissionCategory = "PERMISSION"

    static func registerCategories() {
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [.foreground, .authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: permissionCategory, actions: [allow, deny], intentIdentifiers: [])
        ])
    }

    @MainActor static var appIsActive: Bool { UIApplication.shared.applicationState == .active }

    /// Asks once, at a natural moment (the first time you send something).
    static func authorizeIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    @MainActor
    static func post(_ kind: NotificationKind, title: String, body: String, chatID: UUID?, approvalID: UUID? = nil) {
        guard kind.enabled, !appIsActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(180))
        content.sound = .default
        content.threadIdentifier = chatID?.uuidString ?? kind.rawValue
        if let chatID { content.userInfo = ["chatID": chatID.uuidString, "approvalID": approvalID?.uuidString ?? ""] }
        if kind == .permission { content.categoryIdentifier = permissionCategory; content.interruptionLevel = .timeSensitive }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()
        return true
    }

    /// Don't banner while the app is on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo["chatID"] as? String).flatMap(UUID.init) else { return }
        let action = response.actionIdentifier
        let approval = (response.notification.request.content.userInfo["approvalID"] as? String).flatMap(UUID.init)
        await MainActor.run {
            switch action {
            case "ALLOW": if !AppLock.shared.isLocked { ChatRegistry.model(id)?.resolveApproval(.allow, id: approval) }
            case "DENY": ChatRegistry.model(id)?.resolveApproval(.deny, id: approval)
            default: AppRouter.shared.chatID = id
            }
        }
    }
}

/// Lets a notification action find the running chat.
@MainActor
enum ChatRegistry {
    private final class Box { weak var model: ChatViewModel?; init(_ m: ChatViewModel) { model = m } }
    private static var boxes: [UUID: Box] = [:]
    static func register(_ model: ChatViewModel) { boxes[model.id] = Box(model) }
    static func model(_ id: UUID) -> ChatViewModel? { boxes[id]?.model }
}
