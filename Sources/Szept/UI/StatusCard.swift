import SwiftUI

struct StatusCard: View {
    let mode: SzeptMode
    let description: String

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
        switch mode {
        case .enhanced:   return .green
        case .standalone: return .yellow
        case .off:        return Color(.systemGray)
        }
    }

    private var modeLabel: String {
        switch mode {
        case .enhanced:   return "Enhanced"
        case .standalone: return "Standalone"
        case .off:        return "Off"
        }
    }
}
