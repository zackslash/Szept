import Foundation

enum BundleIdentifiers {
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi"
    ]

    static let electronApps: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.microsoft.teams2"
    ]

    static func isChromiumBrowser(_ bundleID: String) -> Bool {
        chromiumBrowsers.contains(bundleID)
    }

    static func isElectronApp(_ bundleID: String) -> Bool {
        electronApps.contains(bundleID)
    }

    static func isVoiceIsolationIncompatible(_ bundleID: String) -> Bool {
        isChromiumBrowser(bundleID) || isElectronApp(bundleID)
    }
}
