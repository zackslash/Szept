import SwiftUI

struct ControlsSection: View {
    @Environment(AppState.self) var appState
    @AppStorage("qualityPreset") private var qualityPreset: String = "aggressive"

    var body: some View {
        let processor = appState.micProcessor
        VStack(alignment: .leading, spacing: 10) {
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
            .labelsHidden()
            .disabled(!processor.isRunning)
            .onChange(of: qualityPreset) { _, newValue in
                processor.applyQualityPreset(newValue)
            }
        }
    }
}
