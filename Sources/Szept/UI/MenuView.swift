import SwiftUI

struct MenuView: View {
    @Environment(AppState.self) var appState

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
            if appState.shouldShowAppWarning,
               let reason = appState.frontmostAppMonitor.incompatibilityReason {
                AppWarningBanner(reason: reason)
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
            AudioMeter(level: appState.micProcessor.outputLevel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerSection: some View {
        HStack {
            Button("Open Mic Settings") {
                appState.micModeMonitor.openMicModePicker()
            }
            .buttonStyle(.borderless)
            Spacer()
            Button(appState.micProcessor.isRunning ? "Stop" : "Start") {
                toggleEngine()
            }
            .buttonStyle(.borderless)
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toggleEngine() {
        if appState.micProcessor.isRunning {
            appState.micProcessor.stop()
            appState.lastError = nil
            UserDefaults.standard.set(false, forKey: "isProcessingEnabled")
        } else {
            do {
                try appState.micProcessor.start()
                appState.lastError = nil
                UserDefaults.standard.set(true, forKey: "isProcessingEnabled")
            } catch {
                appState.lastError = "Failed to start: \(error.localizedDescription)"
                print("Engine start failed: \(error)")
            }
        }
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

