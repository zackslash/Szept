import SwiftUI

struct StatusCard: View {
    let mode: SzeptMode
    let description: String
    var isMuted: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            modeIndicatorDot
            modeTextStack
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var modeIndicatorDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 10, height: 10)
            .padding(.top, 4)
    }

    private var modeTextStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(modeLabel)
                .font(.subheadline.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        // Muted overrides the mode color: audible state is off even though
        // the engine is still running and monitoring the mic.
        if isMuted { return .orange }
        switch mode {
        case .enhanced:   return .green
        case .standalone: return .blue
        case .off:        return Color(.systemGray)
        }
    }

    private var modeLabel: String {
        switch mode {
        case .enhanced:   return "Szept + Voice Isolation"
        case .standalone: return "Szept active"
        case .off:        return "Off"
        }
    }
}
