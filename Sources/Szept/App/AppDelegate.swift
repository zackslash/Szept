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
        // Before the observer/engine: crash leftovers can include the default output.
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

    /// Quit path: the sharer teardown must run before the process dies, but
    /// it is async (invariant I5: engine/HAL work never on main), so
    /// applicationShouldTerminate dispatches it and waits, pumping the main
    /// run loop (a bare semaphore wait on main would block the Task's
    /// main-actor entry). Bounded at 2s: a parked worker means the reply
    /// fires anyway and the leftover multi-output is owned by
    /// cleanupStaleDevices next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileLog.log("quit: applicationShouldTerminate, dispatching share teardown")
        let done = DispatchSemaphore(value: 0)
        Task { [appState] in
            await appState.systemSharer.disable(restartMic: false)
            done.signal()
        }
        let deadline = Date().addingTimeInterval(2.0)
        while done.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        FileLog.log("quit: share teardown wait done, replying terminate")
        DispatchQueue.main.async {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The sharer teardown already ran (or was abandoned, bounded) in
        // applicationShouldTerminate; it stops the mic engine itself
        // (invariant I1) in the safe order. This second stop is idempotent
        // and only covers the case where the sharer had nothing to do.
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
            // The icon also depends on the voice mute (mic.slash.fill
            // precedence), so track it too.
            _ = appState.micProcessor.voiceMuted
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusItemIcon()
                self?.observeMode()
            }
        }
    }

    func updateStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        // Mute outranks any processing state: a muted mic changes what the call hears.
        let symbolName: String
        if appState.micProcessor.isRunning, appState.micProcessor.voiceMuted {
            symbolName = "mic.slash.fill"
        } else {
            switch appState.currentMode {
            case .enhanced:    symbolName = "checkmark.shield.fill"
            case .standalone:  symbolName = "waveform.circle.fill"
            case .off:         symbolName = "waveform.circle"
            }
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Szept")
        image?.isTemplate = true
        button.image = image
    }
}
