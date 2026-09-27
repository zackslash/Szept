import AppKit
import SwiftUI
import Observation
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileLog.log("app: didFinishLaunching")
        registerDefaults()
        loadPreferencesIntoProcessor()
        setupStatusItem()
        setupHotkeys()
        observeMode()
        checkMicPermission()
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
        appState.micProcessor.stop()
    }

    // MARK: - Defaults

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "launchAtLogin": false,
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
            do {
                try self.appState.resolveAndAssignDevices()
                try self.appState.micProcessor.start()
                let preset = UserDefaults.standard.string(forKey: "qualityPreset") ?? "aggressive"
                self.appState.micProcessor.applyQualityPreset(preset)
                FileLog.log("autoStart: succeeded")
            } catch {
                // A stale device (unplugged mic, vanished BlackHole) is the
                // overwhelmingly likely cause; re-resolve and retry ONCE.
                FileLog.log("autoStart: failed: \(error.localizedDescription); retrying after device re-resolution")
                self.startWithDeviceRetry()
            }
        }
    }

    private func startWithDeviceRetry() {
        do {
            try appState.resolveAndAssignDevices()
            try appState.micProcessor.start()
            let preset = UserDefaults.standard.string(forKey: "qualityPreset") ?? "aggressive"
            appState.micProcessor.applyQualityPreset(preset)
            FileLog.log("autoStart: succeeded after device re-resolution")
        } catch {
            FileLog.log("autoStart: failed after retry: \(error.localizedDescription)")
            appState.lastError = error.localizedDescription
            // Reset the preference so it doesn't keep trying and failing
            UserDefaults.standard.set(false, forKey: "isProcessingEnabled")
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

        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 300)

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
