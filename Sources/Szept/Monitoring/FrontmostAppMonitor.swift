import Foundation
import AppKit

@Observable
final class FrontmostAppMonitor {
    var isVoiceIsolationCompatible: Bool = true
    var incompatibilityReason: String? = nil

    private var observer: NSObjectProtocol?

    init() {
        startObserving()
        checkFrontmostApp(NSWorkspace.shared.frontmostApplication)
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func startObserving() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.checkFrontmostApp(app)
        }
    }

    private func checkFrontmostApp(_ app: NSRunningApplication?) {
        guard let bundleID = app?.bundleIdentifier else {
            isVoiceIsolationCompatible = true
            incompatibilityReason = nil
            return
        }

        if BundleIdentifiers.isVoiceIsolationIncompatible(bundleID) {
            isVoiceIsolationCompatible = false
            incompatibilityReason = "Voice Isolation doesn't work in \(app?.localizedName ?? "this app"). Szept is handling it alone."
        } else {
            isVoiceIsolationCompatible = true
            incompatibilityReason = nil
        }
    }
}
