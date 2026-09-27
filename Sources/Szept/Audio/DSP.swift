import Accelerate
import Foundation

enum DSP {
    /// Apply linear gain to samples in-place using vDSP.
    static func applyMakeupGain(
        samples: UnsafeMutablePointer<Float>,
        count: Int,
        gainLinear: Float
    ) {
        var gain = gainLinear
        vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(count))
    }

    /// Apply tanh soft limiting in-place. Threshold controls the knee point.
    static func applySoftLimiter(
        samples: UnsafeMutablePointer<Float>,
        count: Int,
        threshold: Float
    ) {
        let invThreshold = 1.0 / threshold
        for i in 0..<count {
            samples[i] = threshold * tanh(samples[i] * invThreshold)
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

    /// Convert dB value to linear gain multiplier.
    static func dbToLinear(_ db: Float) -> Float {
        return pow(10.0, db / 20.0)
    }
}
