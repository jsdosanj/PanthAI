import CoreData
import Foundation
import Observation

/// Mirrors your preferences to iCloud's key-value store so a second iPad picks them up.
/// Only the settings listed here travel; security switches, offline mode and anything private to this iPad do not.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()
    private var started = false
    private var applying = false

    private var keys: [String] {
        [Prefs.displayName, Prefs.about, Prefs.style, Prefs.extra, Prefs.useTemperature, Prefs.temperature, Prefs.returnSends, Prefs.focusOnLaunch,
         Prefs.siriContext, Prefs.webSearch, Prefs.codeExecution, Prefs.memory, Prefs.defaultNetwork, Prefs.knowledge, Prefs.knowledgeAuto]
            + NotificationKind.allCases.map(\.prefKey)
    }

    func start() {
        guard !started, AppData.isSyncing else { return }
        started = true
        let store = NSUbiquitousKeyValueStore.default
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
        store.synchronize()
        pull()    // the other iPad's values win on first connect…
        push()    // …and anything it doesn't have yet is sent
    }

    private func pull() {
        applying = true
        defer { applying = false }
        let store = NSUbiquitousKeyValueStore.default, defaults = UserDefaults.standard
        for key in keys {
            guard let value = store.object(forKey: key) else { continue }
            if let b = value as? Bool, defaults.object(forKey: key) as? Bool != b { defaults.set(b, forKey: key) }
            else if let s = value as? String, defaults.string(forKey: key) != s { defaults.set(s, forKey: key) }
            else if let d = value as? Double, defaults.object(forKey: key) as? Double != d { defaults.set(d, forKey: key) }
        }
    }

    private func push() {
        guard !applying else { return }
        let store = NSUbiquitousKeyValueStore.default, defaults = UserDefaults.standard
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let b = value as? Bool, store.object(forKey: key) as? Bool != b { store.set(b, forKey: key) }
            else if let s = value as? String, store.string(forKey: key) != s { store.set(s, forKey: key) }
            else if let d = value as? Double, store.object(forKey: key) as? Double != d { store.set(d, forKey: key) }
        }
    }
}

/// When iCloud last exchanged changes, and the last problem it reported.
@MainActor @Observable
final class SyncStatus {
    static let shared = SyncStatus()
    private(set) var lastSynced: Date?
    private(set) var lastError: String?
    private var started = false

    func start() {
        guard !started, AppData.isSyncing else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  let end = event.endDate else { return }
            let failure = event.succeeded ? nil : event.error?.localizedDescription
            MainActor.assumeIsolated {
                if let failure { self?.lastError = failure } else { self?.lastSynced = end; self?.lastError = nil }
            }
        }
    }
}
