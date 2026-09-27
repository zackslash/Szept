import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            AudioTab()
                .tabItem { Label("Audio", systemImage: "waveform") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 450, height: 300)
    }
}

private struct GeneralTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
            }
            Section {
                Text("Szept runs silently in the menu bar and improves microphone audio locally using Apple's Neural Engine. Audio never leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Hotkeys") {
                ForEach(HotkeyManager.Slot.allCases, id: \.self) { slot in
                    LabeledContent(HotkeyManager.label(for: slot)) {
                        Text(hotkeyCombo(for: slot))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Global hotkeys work system-wide. Combos already claimed by another app are silently skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Read-only display of the current binding. Carbon modifier bits are
    /// rendered as glyphs; unknown key codes fall back to their number.
    private func hotkeyCombo(for slot: HotkeyManager.Slot) -> String {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.prefKey(for: slot)
        let binding = defaults.string(forKey: key).flatMap(HotkeyManager.decode)
            ?? HotkeyManager.defaultBinding(for: slot)

        var glyphs = ""
        if binding.modifierMask & UInt32(controlKey) != 0 { glyphs += "\u{2303}" }  // ^
        if binding.modifierMask & UInt32(optionKey) != 0 { glyphs += "\u{2325}" }   // ⌥
        if binding.modifierMask & UInt32(shiftKey) != 0 { glyphs += "\u{21E7}" }    // ⇧
        if binding.modifierMask & UInt32(cmdKey) != 0 { glyphs += "\u{2318}" }      // ⌘
        return glyphs + HotkeyManager.keyName(keyCode: binding.keyCode)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("SMAppService error: \(error)")
        }
    }
}

private struct AudioTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage("autoAdjust") private var autoAdjust: Bool = false
    @AppStorage("qualityPreset") private var qualityPreset: String = "aggressive"
    @AppStorage("inputDeviceUID") private var inputDeviceUID: String = ""
    @AppStorage("outputDeviceUID") private var outputDeviceUID: String = ""
    @AppStorage("clarityLevel") private var clarityLevel: String = "off"

    @State private var inputDevices: [AudioDeviceInfo] = []
    @State private var outputDevices: [AudioDeviceInfo] = []

    private var blackHoleDetected: Bool {
        outputDevices.contains { $0.name.localizedCaseInsensitiveContains("BlackHole") }
    }

    var body: some View {
        Form {
            Section("Devices") {
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Output device", selection: $outputDeviceUID) {
                    Text("Auto (BlackHole)").tag("")
                    ForEach(outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                if !blackHoleDetected {
                    Text("BlackHole not detected. Install it from existential.audio or pick another loopback device.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Clarity") {
                LabeledContent("Broadcast voice") {
                    Picker("Broadcast voice", selection: $clarityLevel) {
                        ForEach(ClarityLevel.allCases, id: \.self) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .onChange(of: clarityLevel) { _, raw in
                    appState.micProcessor.setClarity(ClarityLevel(rawValue: raw) ?? .off)
                }
                Text("Adds a gentle presence lift with a matching de-esser for a clearer, more broadcast-like voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Isolation") {
                LabeledContent("Strength") {
                    Picker("Strength", selection: $qualityPreset) {
                        Text("Gentle").tag("light")
                        Text("Medium").tag("balanced")
                        Text("Max").tag("aggressive")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadDevices() }
    }

    private func reloadDevices() {
        inputDevices = (try? AudioDeviceManager.inputDevices()) ?? []
        outputDevices = (try? AudioDeviceManager.outputDevices()) ?? []
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Szept")
                .font(.title.weight(.semibold))
            Text("Version \(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Local microphone enhancement using Apple's Neural Engine.\nZero network access. Runs entirely on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
