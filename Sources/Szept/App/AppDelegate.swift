import AppKit
import SwiftUI
import Observation
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager?
    private var lifecycleObserver: LifecycleObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileLog.log("app: didFinishLaunching")
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }
        // The app menu only exists once a real window (Settings) takes focus,
        // so retarget its About item lazily whenever the app becomes active.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        registerDefaults()
        loadPreferencesIntoProcessor()
        // Launch-time stale cleanup BEFORE the lifecycle observer is
        // created and any engine starts: a crashed session can leave the
        // share multi-output behind (possibly as the default output).
        SystemAudioSharer.cleanupStaleDevices()
        setupStatusItem()
        setupHotkeys()
        observeMode()
        lifecycleObserver = LifecycleObserver(appState: appState)
        checkMicPermission()
    }

    /// Replace the standard About panel with our own so the icon always
    /// resolves from the bundle (the standard panel loses it for this
    /// ad hoc signed bundle).
    @objc private func appDidBecomeActive() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        for item in appMenu.items
        where item.action == Selector("orderStandardAboutPanel:") {
            item.target = self
            item.action = #selector(showAboutPanel)
        }
    }

    private var aboutPanel: NSPanel?

    @objc private func showAboutPanel() {
        if aboutPanel == nil {
            let panel = NSPanel(
                contentViewController: NSHostingController(rootView: AboutPanelContent())
            )
            panel.styleMask = [.titled, .closable]
            panel.title = "About Szept"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            // Programmatic panels release themselves on close by default,
            // which would dangle our strong reference on the second open.
            panel.isReleasedWhenClosed = false
            aboutPanel = panel
        }
        aboutPanel?.center()
        aboutPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `szept://` opens are handled here instead of `.onOpenURL`: SwiftUI's
    /// `onOpenURL` is a View modifier and does not reach a menu-bar app whose
    /// content view is not instantiated yet, while the app delegate receives
    /// open events from launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = AppAction.from(url: url) else {
                FileLog.log("url: unrecognized \(url.absoluteString)")
                continue
            }
            FileLog.log("url: \(action) via \(url.absoluteString)")
            DispatchQueue.main.async { [appState] in
                action.perform(on: appState)
            }
        }
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        hotkeyManager = HotkeyManager { [weak self] action in
            FileLog.log("hotkey: \(action)")
            guard let self else { return }
            action.perform(on: self.appState)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Sharer first: it must restore the default output and destroy the
        // multi-output while the mic engine is still alive.
        appState.systemSharer.disable()
        appState.micProcessor.stop()
    }

    // MARK: - Defaults

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "isProcessingEnabled": true,
            "qualityPreset": "aggressive",
            "clarityLevel": "off"
        ])
    }

    private func loadPreferencesIntoProcessor() {
        let clarityRaw = UserDefaults.standard.string(forKey: "clarityLevel") ?? "off"
        appState.micProcessor.setClarity(ClarityLevel(rawValue: clarityRaw) ?? .off)
    }

    // MARK: - Permission + Auto-start

    private func checkMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        FileLog.log("permission: status \(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")
        switch status {
        case .authorized:
            autoStartIfEnabled()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    FileLog.log("permission: prompt answered granted=\(granted)")
                    if granted {
                        self?.autoStartIfEnabled()
                    } else {
                        self?.appState.micPermissionDenied = true
                    }
                }
            }
        case .denied, .restricted:
            FileLog.log("permission: denied or restricted, showing denied card")
            appState.micPermissionDenied = true
        @unknown default:
            break
        }
    }

    private func autoStartIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "isProcessingEnabled") else {
            FileLog.log("autoStart: skipped, preference off")
            return
        }
        FileLog.log("autoStart: scheduling in 0.5s")

        // Delay slightly to ensure audio system is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.appState.startEngineWithRetry(reason: "autoStart")
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemIcon()

        let menu = NSMenu()
        let menuItem = NSMenuItem()
        let hostingView = NSHostingView(
            rootView: MenuView().environment(appState)
        )

        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 360)

        menuItem.view = hostingView
        menu.addItem(menuItem)
        statusItem.menu = menu
    }

    private func observeMode() {
        withObservationTracking {
            _ = appState.currentMode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusItemIcon()
                self?.observeMode()
            }
        }
    }

    func updateStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        switch appState.currentMode {
        case .enhanced:    symbolName = "checkmark.shield.fill"
        case .standalone:  symbolName = "waveform.circle.fill"
        case .off:         symbolName = "waveform.circle"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Szept")
        image?.isTemplate = true
        button.image = image
    }
}
