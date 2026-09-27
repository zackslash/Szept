import AppKit
import SwiftUI
import Observation
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerDefaults()
        loadPreferencesIntoProcessor()
        setupStatusItem()
        observeMode()
        checkMicPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.micProcessor.stop()
    }

    // MARK: - Defaults

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "makeupGainDB": 6.0,
            "autoAdjust": false,
            "launchAtLogin": false,
            "isProcessingEnabled": true,
            "qualityPreset": "aggressive"
        ])
    }

    private func loadPreferencesIntoProcessor() {
        let gainDB = Float(UserDefaults.standard.double(forKey: "makeupGainDB"))
        // Auto-adjust is retired from the UI: it misfires on transient noise
        // such as barking. Force it off so a legacy stored toggle cannot
        // silently re-enable the controller.
        UserDefaults.standard.set(false, forKey: "autoAdjust")
        appState.micProcessor.loadPreferences(gainDB: gainDB, autoAdjust: false)
    }

    // MARK: - Permission + Auto-start

    private func checkMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            autoStartIfEnabled()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.autoStartIfEnabled()
                    } else {
                        self?.appState.micPermissionDenied = true
                    }
                }
            }
        case .denied, .restricted:
            appState.micPermissionDenied = true
        @unknown default:
            break
        }
    }

    private func autoStartIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "isProcessingEnabled") else { return }

        // Delay slightly to ensure audio system is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            do {
                try self.resolveAndAssignDevices()
                try self.appState.micProcessor.start()
                let preset = UserDefaults.standard.string(forKey: "qualityPreset") ?? "aggressive"
                self.appState.micProcessor.applyQualityPreset(preset)
                print("Auto-start succeeded")
            } catch {
                print("Auto-start failed: \(error)")
                self.appState.lastError = error.localizedDescription
                // Reset the preference so it doesn't keep trying and failing
                UserDefaults.standard.set(false, forKey: "isProcessingEnabled")
            }
        }
    }

    /// Resolves the configured input/output devices and assigns them to the
    /// processor. Throws (without starting the engine) if no usable output
    /// device exists — audio is never routed to the system default output,
    /// which would blast the processed mic from the speakers.
    func resolveAndAssignDevices() throws {
        let inputUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? ""
        if !inputUID.isEmpty {
            if let input = try AudioDeviceManager.findDevice(uid: inputUID) {
                appState.micProcessor.inputDeviceID = input.id
            } else {
                throw NSError(domain: "AppDelegate", code: 20,
                              userInfo: [NSLocalizedDescriptionKey: "Selected input device not found. Reconnect it or pick another microphone in Settings."])
            }
        } else {
            appState.micProcessor.inputDeviceID = nil
        }

        let outputUID = UserDefaults.standard.string(forKey: "outputDeviceUID") ?? ""
        if !outputUID.isEmpty {
            if let output = try AudioDeviceManager.findDevice(uid: outputUID) {
                appState.micProcessor.outputDeviceID = output.id
            } else {
                throw NSError(domain: "AppDelegate", code: 21,
                              userInfo: [NSLocalizedDescriptionKey: "Selected output device not found. Reconnect it or pick another device in Settings."])
            }
        } else if let blackHole = try AudioDeviceManager.firstBlackHole() {
            appState.micProcessor.outputDeviceID = blackHole.id
        } else {
            throw NSError(domain: "AppDelegate", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "No output device found. Install BlackHole (existential.audio/blackhole) or pick a device in Settings."])
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

        // Deterministic sizing: propose the fixed panel width and take the
        // height SwiftUI actually needs via sizeThatFits. Ideal-size
        // discovery (preferredContentSize/fittingSize) is unreliable here:
        // it collapsed the panel to a zero-width sliver.
        var panelSize = hostingView.sizeThatFits(
            NSSize(width: 320, height: .greatestFiniteMagnitude)
        )
        panelSize.width = 320
        if panelSize.height < 100 || panelSize.height.isInfinite { panelSize.height = 300 }
        hostingView.frame = NSRect(origin: .zero, size: panelSize)

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
        case .enhanced:    symbolName = "waveform.circle.fill"
        case .standalone:  symbolName = "checkmark.shield.fill"
        case .off:         symbolName = "waveform.circle"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Szept")
        image?.isTemplate = true
        button.image = image
    }
}
