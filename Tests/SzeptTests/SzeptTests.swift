import XCTest
import Accelerate
@testable import Szept

final class DSPTests: XCTestCase {
    // MARK: - applySoftLimiter

    func testSoftLimiterClampsLargeValues() {
        var samples: [Float] = [10.0, -10.0]
        DSP.applySoftLimiter(samples: &samples, count: samples.count, threshold: 0.7)
        XCTAssertTrue(samples[0] < 0.71 && samples[0] > 0.69)
        XCTAssertTrue(samples[1] > -0.71 && samples[1] < -0.69)
    }

    func testSoftLimiterPreservesSmallValues() {
        var samples: [Float] = [0.01, -0.01]
        DSP.applySoftLimiter(samples: &samples, count: samples.count, threshold: 0.7)
        XCTAssertLessThan(abs(samples[0] - 0.01), 0.001)
        XCTAssertLessThan(abs(samples[1] - (-0.01)), 0.001)
    }

    func testSoftLimiterOutputNeverExceedsThreshold() {
        var samples: [Float] = [1.0, 2.0, 5.0, -1.0, -2.0, -5.0]
        DSP.applySoftLimiter(samples: &samples, count: samples.count, threshold: 0.7)
        for s in samples {
            XCTAssertLessThanOrEqual(abs(s), 0.7 + 0.001)
        }
    }

    // MARK: - calculateRMS

    func testRMSOfConstantSignal() {
        let samples: [Float] = [0.5, 0.5, 0.5, 0.5]
        let result = DSP.calculateRMS(samples: samples, count: samples.count)
        XCTAssertLessThan(abs(result - 0.5), 0.0001)
    }

    func testRMSOfSilenceIsZero() {
        let samples: [Float] = [0.0, 0.0, 0.0, 0.0]
        let result = DSP.calculateRMS(samples: samples, count: samples.count)
        XCTAssertEqual(result, 0.0)
    }

    func testRMSOfSineApproximation() {
        let count = 1000
        let samples = (0..<count).map { i -> Float in
            sin(2.0 * Float.pi * Float(i) / Float(count))
        }
        let result = DSP.calculateRMS(samples: samples, count: count)
        XCTAssertLessThan(abs(result - 0.707), 0.01)
    }

    // MARK: - dbToLinear

    func testZeroDBIsUnityGain() {
        XCTAssertLessThan(abs(DSP.dbToLinear(0) - 1.0), 0.0001)
    }

    func testSixDBIsApproximatelyDouble() {
        XCTAssertLessThan(abs(DSP.dbToLinear(6) - 2.0), 0.01)
    }

    func testNegativeSixDBIsApproximatelyHalf() {
        XCTAssertLessThan(abs(DSP.dbToLinear(-6) - 0.5), 0.01)
    }
}

final class ActionRouterURLTests: XCTestCase {
    private func action(_ string: String) -> AppAction? {
        AppAction.from(url: URL(string: string)!)
    }

    func testToggle() {
        XCTAssertEqual(action("szept://toggle"), .toggleEngine)
    }

    func testClarity() {
        XCTAssertEqual(action("szept://clarity"), .cycleClarity)
    }

    func testStrengthDefaultsToUp() {
        XCTAssertEqual(action("szept://strength"), .strengthUp)
    }

    func testStrengthDown() {
        XCTAssertEqual(action("szept://strength/down"), .strengthDown)
    }

    func testMuteVerbWasRemoved() {
        XCTAssertNil(action("szept://mute"))
        XCTAssertNil(action("szept://mute/on"))
    }

    func testBypassOnOffAndToggle() {
        XCTAssertEqual(action("szept://bypass/on"), .bypassOn)
        XCTAssertEqual(action("szept://bypass/off"), .bypassOff)
        XCTAssertEqual(action("szept://bypass"), .bypassToggle)
    }

    func testUnknownSchemeIsNil() {
        XCTAssertNil(AppAction.from(url: URL(string: "http://toggle")!))
        XCTAssertNil(AppAction.from(url: URL(string: "nonoisemac://toggle")!))
    }

    func testUnknownVerbIsNil() {
        XCTAssertNil(action("szept://nonsense"))
        XCTAssertNil(action("szept://"))
    }

    func testCaseInsensitivity() {
        XCTAssertEqual(action("SZEPT://TOGGLE"), .toggleEngine)
        XCTAssertEqual(action("szept://BYPASS/OFF"), .bypassOff)
        XCTAssertEqual(action("szept://Strength/Down"), .strengthDown)
    }
}

final class HotkeyManagerBindingTests: XCTestCase {
    func testEncodeDecodeRoundtrip() {
        let binding = HotkeyManager.Binding(keyCode: 45, modifierMask: 6144)
        let encoded = HotkeyManager.encode(binding)
        XCTAssertEqual(HotkeyManager.decode(encoded), binding)
    }

    func testDecodeGarbageIsNil() {
        XCTAssertNil(HotkeyManager.decode(""))
        XCTAssertNil(HotkeyManager.decode("45"))
        XCTAssertNil(HotkeyManager.decode("a:b"))
        XCTAssertNil(HotkeyManager.decode("45:18432:7"))
    }

    func testEverySlotHasPrefKeyAndDefault() {
        for slot in HotkeyManager.Slot.allCases {
            XCTAssertFalse(HotkeyManager.prefKey(for: slot).isEmpty)
            XCTAssertNotNil(HotkeyManager.decode(HotkeyManager.encode(HotkeyManager.defaultBinding(for: slot))))
        }
    }
}

final class BiquadTests: XCTestCase {
    private func processConstant(_ coefficientSetup: (inout Biquad) -> Void, count: Int = 64) -> [Float] {
        var biquad = Biquad()
        coefficientSetup(&biquad)
        var out: [Float] = []
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(biquad.process(0.3)) }
        return out
    }

    func testBypassIsExactIdentity() {
        let out = processConstant { $0.setBypass() }
        for s in out { XCTAssertEqual(s, 0.3) }
    }

    func testPeakingZeroGainIsIdentity() {
        let out = processConstant { $0.setPeaking(freq: 4500, gainDb: 0, sampleRate: 48000, q: 0.7) }
        for s in out {
            XCTAssertLessThan(abs(s - 0.3), 0.0001)
        }
    }

    func testPeakingLiftsConstantAboveUnity() {
        // A constant DC-ish tone is not the bell's center, but a +4.5 dB
        // peaking filter at q 0.7 must change the signal.
        let out = processConstant { $0.setPeaking(freq: 4500, gainDb: 4.5, sampleRate: 48000, q: 0.7) }
        XCTAssertTrue(out.contains { abs($0 - 0.3) > 0.0001 })
    }

    func testResetClearsState() {
        var driven = Biquad()
        var fresh = Biquad()
        driven.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000)
        fresh.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000)
        _ = driven.process(0.5)          // build internal state
        driven.reset()
        XCTAssertEqual(driven.process(0.5), fresh.process(0.5))
    }
}

final class DeEsserTests: XCTestCase {
    func testBelowThresholdIsExactIdentity() {
        var deEsser = DeEsser()
        deEsser.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 6,
                          attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: true)
        // Low-level signal stays far below the -28 dB threshold: output must
        // equal input bit-exactly.
        let input: [Float] = [0.001, -0.001, 0.0005, -0.0005]
        for x in input {
            XCTAssertEqual(deEsser.process(x), x)
        }
    }

    func testDisabledIsExactIdentity() {
        var deEsser = DeEsser()
        deEsser.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 6,
                          attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: false)
        let input: [Float] = [0.9, -0.9, 0.5, -0.5]
        for x in input {
            XCTAssertEqual(deEsser.process(x), x)
        }
    }
}

final class VoiceChainTests: XCTestCase {
    func testOffIsIdentity() {
        let chain = VoiceChain()
        chain.configure(sampleRate: 48000)
        chain.setClarity(.off)
        var samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let original = samples
        samples.withUnsafeMutableBufferPointer { buf in
            chain.process(buf.baseAddress!, count: buf.count)
        }
        XCTAssertEqual(samples, original)
    }

    func testLowChangesSignal() {
        let chain = VoiceChain()
        chain.configure(sampleRate: 48000)
        chain.setClarity(.low)
        let count = 4800
        var samples = (0..<count).map { i -> Float in
            sin(2.0 * Float.pi * 440.0 * Float(i) / 48000.0) * 0.5
        }
        let original = samples
        samples.withUnsafeMutableBufferPointer { buf in
            chain.process(buf.baseAddress!, count: buf.count)
        }
        XCTAssertTrue(zip(samples, original).contains { abs($0 - $1) > 0.001 })
    }
}
