import Accelerate
import Foundation

enum DSP {
    /// Soft-knee limiter: exact identity below the threshold, a smooth
    /// tanh transition above it approaching unity (full scale). The curve
    /// is continuous with unit slope at the knee, so nominal-level audio
    /// passes untouched and only peaks are tucked in.
    static func applySoftLimiter(
        samples: UnsafeMutablePointer<Float>,
        count: Int,
        threshold: Float
    ) {
        let kneeSpan = 1.0 - threshold
        guard kneeSpan > 0 else { return }
        for i in 0..<count {
            let x = samples[i]
            let magnitude = abs(x)
            guard magnitude > threshold else { continue }
            let shaped = threshold + kneeSpan * tanh((magnitude - threshold) / kneeSpan)
            samples[i] = x < 0 ? -shaped : shaped
        }
    }

    /// Calculate RMS of samples using vDSP.
    static func calculateRMS(
        samples: UnsafePointer<Float>,
        count: Int
    ) -> Float {
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(count))
        return result
    }
}