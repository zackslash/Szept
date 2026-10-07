import Foundation
import CoreAudio

/// SPSC ring carrying system audio samples from the BlackHole capture tap
/// (tap thread, producer) into the mic output unit's render callback
/// (render thread, consumer) where they are mixed into the already
/// filtered/limited mic signal.
///
/// WHY TWO CLOCKS: the system speakers run on the default output's DAC
/// clock (via the multi-output device, which uses the speakers as clock
/// master), while the mic engine renders on the mic interface's clock (via
/// the private aggregate). Those clocks differ by tens of parts per
/// million, so a naive fixed-rate resampler slowly drifts: the ring fills
/// toward overflow (system audio lags) or underruns to silence (system
/// audio leads). Rather than run a full asynchronous sample-rate converter,
/// a small occupancy servo nudges the read ratio by at most a couple of
/// percent toward the target occupancy (a quarter of the ring). The rate change per
/// step is far below audibility (it is what every clock-recovery PLL in a
/// USB audio device does), and the ring depth of ~0.34 s absorbs the
/// moment-to-moment jitter while the servo absorbs the long-term drift.
///
/// Real-time rules: preallocated once, scalar math only, no allocation, no
/// locks, no Objective-C messaging on either audio thread. Barriers mirror
/// MicProcessor.pushToRing/drainRing exactly.
final class SystemMixBus {

    /// Ring capacity: 1 << 14 samples, about 0.34 s at 48 kHz. Allocated
    /// once on first arm and never freed; activity is gated by `active`,
    /// not by a nil pointer, so the render thread never has to re-read the
    /// pointer race-free.
    private let capacity = 1 << 14
    private nonisolated(unsafe) var ring: UnsafeMutablePointer<Float>?

    // Producer side (tap thread).
    nonisolated(unsafe) private var writeIndex = 0

    // Consumer side (render thread only).
    nonisolated(unsafe) private var readIndex = 0
    nonisolated(unsafe) private var phase: Double = 0
    nonisolated(unsafe) private var ratio: Double = 1
    nonisolated(unsafe) private var nominalRatio: Double = 1

    /// Main-thread single-word store with a barrier. Set true LAST on arm
    /// so the render thread that observes true also observes the reset
    /// indices and ratio.
    nonisolated(unsafe) private var active = false

    /// Fixed mix gain for the system audio leg.
    private let gain: Float = 0.8

    var isActive: Bool { active }

    /// Called on the share queue (enable's arm step). Allocate the ring on
    /// first use and reset the bridge.
    /// `inputRate` is the capture tap rate (BlackHole, pinned to 48 kHz by
    /// the sharer), `outputRate` the mic engine's render rate.
    func arm(inputRate: Double, outputRate: Double) {
        if ring == nil {
            ring = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        }
        writeIndex = 0
        readIndex = 0
        phase = 0
        nominalRatio = (inputRate > 0 && outputRate > 0) ? inputRate / outputRate : 1
        ratio = nominalRatio
        // Barrier: publish all of the above before the activity flag.
        OSMemoryBarrier()
        active = true
    }

    /// Called on main (disable's entry and the watchdog's fired path) and
    /// on the share queue (enable rollback). Stop mixing; the ring is
    /// intentionally NOT freed or
    /// reset so the render thread can never observe a dangling pointer.
    /// Safe off-main: single-word store with a barrier, render-side
    /// effects gated by isActive, and transitions are serialized by the
    /// sharer's isBusy window.
    func disarm() {
        active = false
        OSMemoryBarrier()
    }

    /// Tap thread (producer). Same barrier discipline as
    /// MicProcessor.pushToRing: acquire before trusting the read index,
    /// release before publishing the write index. On overflow this drops
    /// the OLDEST incoming samples, keeping the newest - stay live, don't
    /// accumulate latency. Deliberate asymmetry with
    /// MicProcessor.pushToRing: the voice path preserves continuity
    /// (oldest wins) because a word dropped mid-word is a glitch, while a
    /// live mix must not build up delay; falling seconds behind the video
    /// is the worse failure.
    nonisolated func push(samples: UnsafePointer<Float>, count: Int) {
        guard let ring else { return }
        let readIndex = self.readIndex
        // Acquire: observe the samples before trusting the read index.
        OSMemoryBarrier()
        let available = (capacity + readIndex - writeIndex - 1 + capacity) % capacity
        let n = min(count, available)
        let start = count - n
        for i in 0..<n {
            ring[(writeIndex + i) % capacity] = samples[start + i]
        }
        // Release: publish the samples before the write index.
        OSMemoryBarrier()
        writeIndex = (writeIndex + n) % capacity
    }

    /// Tap thread. Downmixes (ch0 + ch1) * 0.5 inline. No allocation.
    nonisolated func pushStereo(ch0: UnsafePointer<Float>, ch1: UnsafePointer<Float>, count: Int) {
        guard let ring else { return }
        let readIndex = self.readIndex
        OSMemoryBarrier()
        let available = (capacity + readIndex - writeIndex - 1 + capacity) % capacity
        let n = min(count, available)
        let start = count - n   // overflow: keep the NEWEST n, drop the OLDEST incoming (stay live)
        for i in 0..<n {
            ring[(writeIndex + i) % capacity] = (ch0[start + i] + ch1[start + i]) * 0.5
        }
        OSMemoryBarrier()
        writeIndex = (writeIndex + n) % capacity
    }

    /// Render thread (consumer). Called from drainRing AFTER the mic
    /// sample/zero-fill loops: adds `gain * sys` into every channel buffer
    /// on top of whatever the mic path wrote. Advances the read position by
    /// the servo ratio per output frame; on a full underrun (nothing mixed)
    /// it publishes nothing (no advance) and returns false.
    ///
    /// Must not allocate or block.
    nonisolated func readMixing(into list: UnsafeMutableAudioBufferListPointer, frames: Int) -> Bool {
        // Acquire for the arm()-published trio (readIndex/phase/ratio and
        // nominalRatio); the caller's plain isActive load does not order
        // them.
        OSMemoryBarrier()
        guard let ring else { return false }

        var mixedAny = false
        var localRead = readIndex
        var localPhase = phase
        var localRatio = ratio

        for i in 0..<frames {
            // Acquire: observe the samples before trusting the write index.
            let writeIndex = self.writeIndex
            OSMemoryBarrier()
            let occupancy = (capacity + writeIndex - Int(localRead)) % capacity
            if occupancy == 0 {
                // Underrun: freeze. Do not advance readIndex/phase so the
                // servo does not burn through the ring during a capture
                // gap, and keep the last ratio.
                break
            }

            // Linear interpolation between position and position + 1; the
            // ring always holds at least one sample here.
            let pos = Double(localRead) + localPhase
            let idx0 = Int(pos) % capacity
            let idx1 = (idx0 + 1) % capacity
            let frac = Float(pos - Double(Int(pos)))
            let s0 = ring[idx0]
            let s1 = occupancy > 1 ? ring[idx1] : s0
            let sys = gain * (s0 + (s1 - s0) * frac)

            for buffer in list {
                if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    data[i] += sys
                }
            }
            mixedAny = true

            // Occupancy servo: target a quarter ring full. The correction
            // is capped at two percent so the instantaneous pitch error
            // stays inaudible.
            let quarter = Double(capacity) / 4
            let correction = max(-0.02, min(0.02, 0.02 * (Double(occupancy) - quarter) / quarter))
            localRatio = nominalRatio * (1 + correction)

            localPhase += localRatio
            while localPhase >= 1 {
                localPhase -= 1
                localRead = (localRead + 1) % capacity
            }
        }

        // Publish once at the end (release barrier), covering both the
        // normal exit and the underrun break.
        if mixedAny {
            OSMemoryBarrier()
            readIndex = localRead
            phase = localPhase
            ratio = localRatio
        }
        return mixedAny
    }
}
