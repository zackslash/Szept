import SwiftUI

struct ControlsSection: View {
    @Environment(AppState.self) var appState
    @AppStorage("qualityPreset") private var qualityPreset: String = "aggressive"

    var body: some View {
        let processor = appState.micProcessor
        VStack(alignment: .leading, spacing: 10) {
            qualityRow(processor: processor)
            muteRow
            shareRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func qualityRow(processor: MicProcessor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Strength")
                .font(.subheadline)
            Picker("Strength", selection: $qualityPreset) {
                Text("Gentle").tag("light")
                Text("Medium").tag("balanced")
                Text("Max").tag("aggressive")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!processor.isRunning)
            .onChange(of: qualityPreset) { _, newValue in
                processor.applyQualityPreset(newValue)
            }
        }
    }

    private var muteRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Mute mic", isOn: Binding(
                get: { appState.micProcessor.voiceMuted },
                set: { _ in AppAction.voiceMuteToggle.perform(on: appState) }
            ))
            .disabled(!appState.micProcessor.isRunning)
            if appState.micProcessor.voiceMuted {
                Text(appState.systemSharer.isSharing
                     ? "Mic muted. System audio still flows to the call."
                     : "Mic muted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shareRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Share system audio", isOn: Binding(
                get: { appState.systemSharer.isSharing },
                set: { _ in AppAction.shareToggle.perform(on: appState) }
            ))
            .disabled(!appState.micProcessor.isRunning)
            if appState.systemSharer.isSharing {
                Text("System audio is mixed into the call. Point Teams speakers at your real output to avoid echo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
