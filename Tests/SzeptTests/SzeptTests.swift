import XCTest
import Accelerate
@testable import Szept

final class DSPTests: XCTestCase {
    // MARK: - applyMakeupGain

    func testGainDoublesAmplitude() {
        var samples: [Float] = [0.5, -0.5, 0.25, -0.25]
        DSP.applyMakeupGain(samples: &samples, count: samples.count, gainLinear: 2.0)
        XCTAssertLessThan(abs(samples[0] - 1.0), 0.0001)
        XCTAssertLessThan(abs(samples[1] - (-1.0)), 0.0001)
        XCTAssertLessThan(abs(samples[2] - 0.5), 0.0001)
    }

    func testGainOfOneIsPassthrough() {
        var samples: [Float] = [0.3, -0.7, 0.1]
        let original = samples
        DSP.applyMakeupGain(samples: &samples, count: samples.count, gainLinear: 1.0)
        for i in samples.indices {
            XCTAssertLessThan(abs(samples[i] - original[i]), 0.0001)
        }
    }

    func testGainZeroSilences() {
        var samples: [Float] = [0.5, -0.5, 0.3]
        DSP.applyMakeupGain(samples: &samples, count: samples.count, gainLinear: 0.0)
        for s in samples { XCTAssertEqual(s, 0.0) }
    }

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

    // MARK: - BundleIdentifiers Tests

    func testChromiumBrowsersDetected() {
        let known = [
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
            "com.operasoftware.Opera",
            "com.vivaldi.Vivaldi"
        ]
        for id in known {
            XCTAssertTrue(BundleIdentifiers.isChromiumBrowser(id), "\(id) should be Chromium")
        }
    }

    func testElectronAppsDetected() {
        let known = [
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.microsoft.teams2"
        ]
        for id in known {
            XCTAssertTrue(BundleIdentifiers.isElectronApp(id), "\(id) should be Electron")
        }
    }

    func testUnknownBundleIDsReturnFalse() {
        XCTAssertFalse(BundleIdentifiers.isChromiumBrowser("com.apple.safari"))
        XCTAssertFalse(BundleIdentifiers.isElectronApp("com.apple.mail"))
        XCTAssertFalse(BundleIdentifiers.isChromiumBrowser(""))
    }

    func testVoiceIsolationIncompatibleCoversAll() {
        for id in BundleIdentifiers.chromiumBrowsers {
            XCTAssertTrue(BundleIdentifiers.isVoiceIsolationIncompatible(id))
        }
        for id in BundleIdentifiers.electronApps {
            XCTAssertTrue(BundleIdentifiers.isVoiceIsolationIncompatible(id))
        }
    }
}
