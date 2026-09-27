import SwiftUI

struct AudioMeter: View {
    let level: Float

    var body: some View {
        EquatableView(content: AudioMeterBar(level: level))
    }
}

private struct AudioMeterBar: View, Equatable {
    let level: Float

    static func == (lhs: AudioMeterBar, rhs: AudioMeterBar) -> Bool {
        abs(lhs.level - rhs.level) < 0.01
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.fill.tertiary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(meterGradient)
                    .frame(width: geometry.size.width * CGFloat(min(level, 1.0)))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
        .frame(height: 8)
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green, location: 0.0),
                .init(color: .green, location: 0.5),
                .init(color: .yellow, location: 0.7),
                .init(color: .red, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
