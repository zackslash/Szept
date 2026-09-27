import SwiftUI
import ServiceManagement

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
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
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
    @AppStorage("autoAdjust") private var autoAdjust: Bool = false
    @AppStorage("qualityPreset") private var qualityPreset: String = "aggressive"
    @AppStorage("inputDeviceUID") private var inputDeviceUID: String = ""
    @AppStorage("outputDeviceUID") private var outputDeviceUID: String = ""

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
            Section("Isolation") {
                Toggle("Auto-adjust strength", isOn: $autoAdjust)
                LabeledContent("Strength") {
                    Picker("Strength", selection: $qualityPreset) {
                        Text("Gentle").tag("light")
                        Text("Medium").tag("balanced")
                        Text("Max").tag("aggressive")
                    }
                    .pickerStyle(.segmented)
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
