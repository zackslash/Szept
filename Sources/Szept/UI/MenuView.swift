import SwiftUI
import AppKit

struct MenuView: View {
    @Environment(AppState.self) var appState

    // SettingsLink alone does nothing when the settings window is already
    // open but buried behind other windows: it neither raises nor
    // activates it, and the window gets lost. Send the settings action,
    // then pull the app forward and front its regular windows (the menu
    // popup and About panel are NSPanels and excluded).
    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        FileLog.log("settings: sent showSettingsWindow action")
        // Defer the activate/raise one turn: SwiftUI materializes the
        // settings window asynchronously, so raising synchronously can
        // miss it (and would leave the first open buried).
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where !(window is NSPanel) && window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
            meterSection
            Divider().padding(.horizontal, 12)
            ControlsSection()
            Divider().padding(.horizontal, 12)
            footerSection
        }
        .frame(width: 320)
        .padding(.vertical, 8)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.micPermissionDenied {
                MicPermissionDeniedCard()
            } else {
                StatusCard(
                    mode: appState.currentMode,
                    description: appState.statusDescription
                )
            }
            if let errorMessage = appState.lastError {
                ErrorBanner(message: errorMessage) {
                    appState.lastError = nil
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output level")
                .font(.caption)
                .foregroundStyle(.secondary)
            AudioMeter(level: appState.micProcessor.outputLevel).equatable()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    appState.micModeMonitor.openMicModePicker()
                } label: {
                    Text("Open Mic Settings")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                Button("Settings…") {
                    openSettings()
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider().padding(.horizontal, 12)

            HStack(spacing: 16) {
                Button(appState.micProcessor.isBypassed ? "A/B" : "Bypass") {
                    appState.micProcessor.setBypassed(!appState.micProcessor.isBypassed)
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .disabled(!appState.micProcessor.isRunning)
                Button(appState.micProcessor.isRunning ? "Stop" : "Start") {
                    AppAction.toggleEngine.perform(on: appState)
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .padding(.vertical, 2)
    }
}

private struct MicPermissionDeniedCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Microphone access denied")
                .font(.subheadline.weight(.semibold))
            Text("Szept needs microphone access to process audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Privacy Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }
}
private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

