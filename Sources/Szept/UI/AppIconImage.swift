import SwiftUI

/// Loads the bundled `AppIcon.icns`. Shared by the Settings About card and
/// the custom About panel. SwiftUI `Image` cannot read `.icns` assets by
/// name, and `NSApplication.icon` may not be set yet when a window opens.
struct AppIconImage: View {
    var body: some View {
        Image(nsImage: Self.loadAppIcon())
            .resizable()
    }

    private static func loadAppIcon() -> NSImage {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            return icon
        }
        return NSImage(size: NSSize(width: 48, height: 48))
    }
}

/// Content for the custom About panel that replaces the standard one (the
/// standard panel resolves its icon through LaunchServices, which does not
/// reliably find the icon for this bundle).
struct AboutPanelContent: View {
    var body: some View {
        VStack(spacing: 10) {
            AppIconImage()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            Text("Szept")
                .font(.title3.weight(.semibold))
            Text("Version \(Self.appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Microphone noise isolation for calls.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 280)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
