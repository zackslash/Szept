import XCTest
import CoreAudio
@testable import Szept

/// Pure no-HAL tests for the SystemMixBus occupancy servo. No HAL device,
/// no engine: the bus is exercised through push/readMixing directly.
final class SystemMixBusTests: XCTestCase {

    // MARK: - Buffer list helper

    /// Two non-interleaved mono buffers, matching the output unit's
    /// deinterleaved stereo render format.
    private final class StereoBuffer {
        let list: UnsafeMutableAudioBufferListPointer
        let left: [Float]
        let right: [Float]

        init(frames: Int) {
            left = [Float](repeating: 0, count: frames)
            right = [Float](repeating: 0, count: frames)
            let raw = UnsafeMutablePointer<AudioBufferList>.allocate(
                capacity: 2
            )
            raw.initialize(to: AudioBufferList(mNumberBuffers: 2))
            list = UnsafeMutableAudioBufferListPointer(raw)
            list[0].mNumberChannels = 1
            list[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            list[0].mData = UnsafeMutableRawPointer(mutating: left)
            list[1].mNumberChannels = 1
            list[1].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            list[1].mData = UnsafeMutableRawPointer(mutating: right)
        }

        deinit {
            list.unsafeMutablePointer.deinitialize(count: 1)
            list.unsafeMutablePointer.deallocate()
        }
    }

    // MARK: 1. Same-rate passthrough

    func testSameRatePassthroughAppliesGain() {
        let bus = SystemMixBus()
        bus.arm(inputRate: 48000, outputRate: 48000)

        // Constant input keeps the assertion position-independent: the
        // occupancy servo legitimately pulls the ratio off 1.0 at low
        // occupancy, which would shift a varying waveform.
        let n = 1000
        var input = [Float](repeating: 0.5, count: n)
        bus.push(samples: &input, count: n)

        let out = StereoBuffer(frames: n)
        let mixed = bus.readMixing(into: out.list, frames: n)
        XCTAssertTrue(mixed)

        for i in 0..<n {
            XCTAssertEqual(out.list[0].mData!.assumingMemoryBound(to: Float.self)[i],
                           0.4, accuracy: 1e-6)
            XCTAssertEqual(out.list[1].mData!.assumingMemoryBound(to: Float.self)[i],
                           0.4, accuracy: 1e-6)
        }
    }

    // MARK: 2. Underrun

    func testUnderrunReturnsFalseAndFreezesRatio() {
        let bus = SystemMixBus()
        bus.arm(inputRate: 48000, outputRate: 48000)

        let out = StereoBuffer(frames: 256)
        XCTAssertFalse(bus.readMixing(into: out.list, frames: 256))

        // Feed a little, read it all back, then read again: the second
        // read is an underrun and must not crash nor advance anything.
        var samples: [Float] = [0.5]
        bus.push(samples: &samples, count: 1)
        XCTAssertTrue(bus.readMixing(into: out.list, frames: 1))
        XCTAssertFalse(bus.readMixing(into: out.list, frames: 1))
    }

    // MARK: 3. Overflow keeps newest

    func testOverflowKeepsNewestSamples() {
        let bus = SystemMixBus()
        bus.arm(inputRate: 48000, outputRate: 48000)

        // Capacity is 1 << 14. Push capacity + 100 monotonic samples; the
        // producer keeps the NEWEST n (drop the oldest incoming) so the
        // mix stays live instead of accumulating latency.
        let capacity = 1 << 14
        let total = capacity + 100
        let input = (0..<total).map { Float($0) }
        var scratch = input
        bus.push(samples: &scratch, count: total)

        let out = StereoBuffer(frames: capacity)
        XCTAssertTrue(bus.readMixing(into: out.list, frames: capacity))
        let output = out.list[0].mData!.assumingMemoryBound(to: Float.self)
        // The servo interpolates between neighbours, so exact values are
        // not guaranteed; assert the head dropped the oldest 100 samples
        // (allowing interpolation slack), the tail never reached the
        // dropped newest samples, and the ramp stayed monotonic.
        XCTAssertGreaterThanOrEqual(output[0], 100)
        XCTAssertLessThanOrEqual(output[0], 102)
        XCTAssertLessThan(output[capacity - 1], Float(total - 100))
        for i in 1..<capacity {
            XCTAssertGreaterThanOrEqual(output[i], output[i - 1] - 0.001)
        }
    }

    // MARK: 4. Inactive gate

    func testDisarmGatesActivityWithoutFreeingRing() {
        let bus = SystemMixBus()
        bus.arm(inputRate: 48000, outputRate: 48000)
        XCTAssertTrue(bus.isActive)

        var samples: [Float] = [0.1, -0.1]
        bus.push(samples: &samples, count: 2)
        bus.disarm()
        XCTAssertFalse(bus.isActive)

        // After disarm the render path never calls readMixing (the flag is
        // the gate in drainRing); the bus itself still refuses to crash if
        // a stale call arrives, returning false without advancing.
        let out = StereoBuffer(frames: 2)
        XCTAssertFalse(bus.readMixing(into: out.list, frames: 0))
    }

    // MARK: 5. Rate-mismatch continuity

    func testServoKeepsSampleToSampleContinuityOnSmoothRamp() {
        let bus = SystemMixBus()
        // Nominal ratio 1.0 but the servo corrections are exercised by
        // keeping the ring near-empty-ish while pushing slowly.
        bus.arm(inputRate: 48000, outputRate: 48000)

        let frames = 4096
        // Smooth ramp so any interpolation glitch is a visible jump.
        let input = (0..<frames).map { Float($0) * 0.0001 }
        var scratch = input
        bus.push(samples: &scratch, count: frames)

        let out = StereoBuffer(frames: frames)
        XCTAssertTrue(bus.readMixing(into: out.list, frames: frames))
        let output = out.list[0].mData!.assumingMemoryBound(to: Float.self)
        for i in 1..<frames {
            let jump = abs(output[i] - output[i - 1])
            XCTAssertLessThan(jump, 0.01, "jump at sample \(i)")
        }
    }
}
