import Foundation

/// File protection for everything the app stores. By default iPadOS keeps files encrypted until you first unlock
/// after a restart. “Maximum protection” re-encrypts them whenever the iPad is locked, which also stops
/// Shortcuts automations from running while it is locked.
enum DataProtection {
    static var maximum: Bool { UserDefaults.standard.bool(forKey: Prefs.maxProtection) }

    static func apply() {
        let level: FileProtectionType = maximum ? .complete : .completeUntilFirstUserAuthentication
        let manager = FileManager.default
        let roots = [URL.applicationSupportDirectory, URL.documentsDirectory]
        for root in roots {
            try? manager.setAttributes([.protectionKey: level], ofItemAtPath: root.path)
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where !url.path.contains("/Models/") {   // multi-GB weights stay readable for background downloads
                try? manager.setAttributes([.protectionKey: level], ofItemAtPath: url.path)
            }
        }
    }
}
