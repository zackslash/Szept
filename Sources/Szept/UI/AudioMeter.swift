import SwiftUI

struct AudioMeter: View, Equatable {
    let level: Float

    // Level hysteresis: ignore sub-0.01 changes so the meter does not
    // re-render on every sample.
    static func == (lhs: AudioMeter, rhs: AudioMeter) -> Bool {
        abs(lhs.level - rhs.level) < 0.01
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.fill.tertiary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(meterGradient)
                    .frame(width: geometry.size.width * CGFloat(displayPosition))
            }
        }
        .frame(height: 8)
    }

    // Display-only remap: position the bar on a decibel scale instead of
    // linear RMS. The audio signal itself is untouched. Linear mapping made
    // normal speech (RMS roughly 0.02 to 0.08) a barely visible sliver.
    // floorDB/ceilingDB clamp the useful range at -60 to 0 dBFS.
    private var displayPosition: Float {
        let floorDB: Float = -60
        let ceilingDB: Float = 0
        let db = 20 * log10(max(level, 0.00001))
        return min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
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
