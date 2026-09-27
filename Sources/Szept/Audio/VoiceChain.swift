import Foundation

// MARK: - Clarity level

/// "Broadcast Voice" intensity. Drives a coupled presence lift + de-esser so
/// the voice sounds clearer and more present while keeping its identity.
/// `.off` is a true no-op (presence bypassed, de-esser identity).
enum ClarityLevel: String, CaseIterable {
    case off
    case low
    case medium
    case high

    var label: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// Presence (peaking-bell) lift in dB. Conservative by design: a gentle,
    /// wide lift adds clarity without coloring the voice.
    var presenceDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 1.5
        case .medium: return 3.0
        case .high:   return 4.5
        }
    }

    /// Maximum de-esser reduction (dB) of the sibilant band. Scales WITH the
    /// presence lift so added "air" never turns into harsh sibilance.
    var deEssMaxReductionDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 4
        case .medium: return 6
        case .high:   return 8
        }
    }
}

// MARK: - Clarity constants

/// Fixed band/timing constants for the clarity stages (tunable starting points).
enum ClarityProfile {
    static let presenceHz: Float = 4500
    static let presenceQ: Float = 0.7
    static let deEssCrossoverHz: Float = 6000
    static let deEssThresholdDb: Float = -28
    static let deEssAttackMs: Float = 1
    static let deEssReleaseMs: Float = 80
}

// MARK: - Biquad (RBJ cookbook, transposed direct form II)

/// Normalized biquad (a0 == 1). Per-sample, allocation-free; state is two
/// scalars carried across calls.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    mutating func setBypass() {
        b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
    }

    /// RBJ high-pass.
    mutating func setHighPass(freq: Float, sampleRate: Float, q: Float = 0.707) {
        let w0 = 2 * Float.pi * max(freq, 1) / sampleRate
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / (2 * q)
        let a0 = 1 + alpha
        b0 = (1 + cs) / 2 / a0
        b1 = -(1 + cs) / a0
        b2 = (1 + cs) / 2 / a0
        a1 = (-2 * cs) / a0
        a2 = (1 - alpha) / a0
    }

    /// RBJ peaking EQ (bell). Unity gain at DC and Nyquist; boosts `gainDb`
    /// around `freq`. A wide q (~0.7) gives a broad, musical lift.
    mutating func setPeaking(freq: Float, gainDb: Float, sampleRate: Float, q: Float = 0.7) {
        let A = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * max(freq, 1) / sampleRate
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / (2 * max(q, 0.0001))
        let a0 = 1 + alpha / A
        b0 = (1 + alpha * A) / a0
        b1 = (-2 * cs) / a0
        b2 = (1 - alpha * A) / a0
        a1 = (-2 * cs) / a0
        a2 = (1 - alpha / A) / a0
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

// MARK: - De-esser

/// Subtractive split-band de-esser. Isolates the sibilant band with a high-pass,
/// follows its envelope, and removes a fraction of that band when it exceeds
/// threshold: `out = x - frac*sib`. Below threshold (and when disabled) `frac = 0`,
/// so output == input exactly. Per-sample, allocation-free.
struct DeEsser {
    private var sib = Biquad()           // high-pass isolating the sibilant band
    private var enabled = false
    private var thresholdLin: Float = 1  // detector threshold (linear)
    private var maxReduction: Float = 0  // max fraction of the sib band to remove (0...1)
    private var attackCoeff: Float = 0
    private var releaseCoeff: Float = 0
    private var env: Float = 0           // smoothed |sib| envelope (linear)

    mutating func configure(crossoverHz: Float, thresholdDb: Float, maxReductionDb: Float,
                            attackMs: Float, releaseMs: Float, sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { sib.setBypass(); env = 0; return }
        sib.setHighPass(freq: crossoverHz, sampleRate: sampleRate, q: 0.707)
        thresholdLin = powf(10, thresholdDb / 20)
        // Convert "max dB to pull the band down" into a max removed-fraction, so
        // out = x - frac*sib reduces the band by at most maxReductionDb and never
        // inverts it.
        maxReduction = min(1, 1 - powf(10, -abs(maxReductionDb) / 20))
        attackCoeff = expf(-1.0 / (max(attackMs, 0.01) * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    mutating func reset() { env = 0; sib.reset() }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let s = sib.process(x)                 // sibilant band (state advances every sample)
        let mag = abs(s)
        let coeff = mag > env ? attackCoeff : releaseCoeff
        env = coeff * env + (1 - coeff) * mag
        guard env > thresholdLin else { return x }   // below threshold: exact identity
        let over = env / thresholdLin                // > 1 here
        let frac = maxReduction * (1 - 1 / over)     // 0 at threshold, maxReduction when loud
        return x - frac * s                          // remove only the sibilant band
    }
}

// MARK: - VoiceChain

/// Time-domain clarity chain: presence peaking bell -> subtractive de-esser.
/// `setClarity`/`configure` run on the main thread; `process` runs on the audio
/// render thread and is allocation- and lock-free.
///
/// Thread-safety mirrors the `tapIsolation` pattern: the main thread only ever
/// writes the pending scalar level; the render thread owns ALL filter state and
/// rebuilds coefficients (allocation-free struct writes) when it observes a
/// level change at the next buffer boundary. Off is a true no-op.
final class VoiceChain {
    nonisolated(unsafe) private var pendingLevel: ClarityLevel = .off
    // Render-thread-owned state below. `appliedLevel` is nil until the chain
    // has been armed with a sample rate and has rebuilt its coefficients.
    private var appliedLevel: ClarityLevel?
    private var sampleRate: Float = 0
    private var presence = Biquad()
    private var deEsser = DeEsser()

    /// Arm the chain with the render sample rate. Call from main before/at
    /// engine start; coefficients are (re)built on the render thread.
    func configure(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    /// Set the clarity level. Main thread only; plain scalar store (atomic on
    /// arm64), picked up by the render thread at the next buffer.
    func setClarity(_ level: ClarityLevel) {
        pendingLevel = level
    }

    var currentLevel: ClarityLevel { pendingLevel }

    /// Reset is folded into the level rebuild so a changed level never rings
    /// with stale envelope/filter state.
    private func rebuild(level: ClarityLevel) {
        presence.reset()
        deEsser.reset()
        if level == .off {
            presence.setBypass()
            deEsser.configure(crossoverHz: ClarityProfile.deEssCrossoverHz,
                              thresholdDb: ClarityProfile.deEssThresholdDb,
                              maxReductionDb: 0,
                              attackMs: ClarityProfile.deEssAttackMs,
                              releaseMs: ClarityProfile.deEssReleaseMs,
                              sampleRate: sampleRate, enabled: false)
        } else {
            presence.setPeaking(freq: ClarityProfile.presenceHz,
                                gainDb: level.presenceDb,
                                sampleRate: sampleRate,
                                q: ClarityProfile.presenceQ)
            deEsser.configure(crossoverHz: ClarityProfile.deEssCrossoverHz,
                              thresholdDb: ClarityProfile.deEssThresholdDb,
                              maxReductionDb: level.deEssMaxReductionDb,
                              attackMs: ClarityProfile.deEssAttackMs,
                              releaseMs: ClarityProfile.deEssReleaseMs,
                              sampleRate: sampleRate, enabled: true)
        }
    }

    /// Process `count` samples in place. No-op when off. Must not allocate
    /// or block; runs on the audio render thread.
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        let level = pendingLevel
        if sampleRate > 0 && level != appliedLevel {
            rebuild(level: level)
            appliedLevel = level
        }
        guard level != .off else { return }
        for i in 0..<count {
            var x = samples[i]
            x = presence.process(x)
            x = deEsser.process(x)
            samples[i] = x
        }
    }
}
