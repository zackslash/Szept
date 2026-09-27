import SwiftUI

struct ControlsSection: View {
    @Environment(AppState.self) var appState
    @AppStorage("qualityPreset") private var qualityPreset: String = "balanced"

    var body: some View {
        @Bindable var processor = appState.micProcessor
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Auto-adjust strength", isOn: $processor.autoAdjust)
                .disabled(!processor.isRunning)
                .onChange(of: processor.autoAdjust) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "autoAdjust")
                }
            Text("Rides strength to keep output loudness steady. Poor match for sudden noise such as barking.")
                .font(.caption)
                .foregroundStyle(.secondary)
            qualityRow(processor: processor)
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
            .disabled(!processor.isRunning)
            .onChange(of: qualityPreset) { _, newValue in
                processor.applyQualityPreset(newValue)
            }
        }
    }
}
