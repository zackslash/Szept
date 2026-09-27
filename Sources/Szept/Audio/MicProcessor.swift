import Foundation
import AVFoundation
import AudioToolbox
import Accelerate
import os.log

@Observable
final class MicProcessor {
    // MARK: - Public state (main thread only)
    var isRunning: Bool = false
    var outputLevel: Float = 0
    var currentIsolation: Float = 50

    var makeupGainDB: Float = 6.0 {
        didSet { tapGainLinear = DSP.dbToLinear(makeupGainDB) }
    }

    var autoAdjust: Bool = true {
        didSet { tapAutoAdjust = autoAdjust }
    }

    // MARK: - Audio thread state (read from tap callback — nonisolated(unsafe))
    // Prefixed with "tap" to avoid conflict with @Observable macro synthesized names.
    nonisolated(unsafe) private var tapGainLinear: Float = DSP.dbToLinear(6.0)
    nonisolated(unsafe) private var tapAutoAdjust: Bool = true
    nonisolated(unsafe) private var tapIsolation: Float = 50

    // MARK: - Device routing (set before start())
    var inputDeviceID: AudioDeviceID?
    var outputDeviceID: AudioDeviceID?

    // MARK: - AVAudioEngine
    private var engine = AVAudioEngine()
    private var isolationUnit: AVAudioUnitEffect?
    private let logger = Logger(subsystem: "dev.kocheck.Szept", category: "MicProcessor")

    // MARK: - AUSoundIsolation component description
    private static var isolationDescription: AudioComponentDescription = {
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = 0x766F6973 // 'vois'
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        desc.componentFlags = 0
        desc.componentFlagsMask = 0
        return desc
    }()

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        // Always create a fresh engine to avoid state issues
        // If there was a previous session, this ensures clean restart
        engine = AVAudioEngine()
        isolationUnit = nil

        do {
            // Safety net for callers that don't resolve devices first
            // (e.g. the menu bar toggle): never render to the system default
            // output, which would blast the processed mic from the speakers.
            if outputDeviceID == nil {
                outputDeviceID = try AudioDeviceManager.firstBlackHole()?.id
                if outputDeviceID == nil {
                    throw NSError(domain: "MicProcessor", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "No output device found. Install BlackHole (existential.audio/blackhole) or pick a device in Settings."])
                }
            }
            if let id = inputDeviceID {
                try setDevice(id, on: engine.inputNode)
            }
            if let id = outputDeviceID {
                try setDevice(id, on: engine.outputNode)
            }
        } catch {
            isolationUnit = nil
            throw error
        }

        let unit = AVAudioUnitEffect(audioComponentDescription: Self.isolationDescription)
        isolationUnit = unit

        engine.attach(unit)
        
        // Get the input format before making connections
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            engine.detach(unit)
            isolationUnit = nil
            throw NSError(domain: "MicProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio input format"])
        }
        
        // Connect nodes with explicit format
        let mixerNode = engine.mainMixerNode
        engine.connect(engine.inputNode, to: unit, format: inputFormat)
        engine.connect(unit, to: mixerNode, format: inputFormat)
        engine.connect(mixerNode, to: engine.outputNode, format: nil)

        setIsolationParameter(tapIsolation)
        
        // Install tap BEFORE starting the engine
        installTap()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            mixerNode.removeTap(onBus: 0)
            engine.detach(unit)
            isolationUnit = nil
            throw error
        }

        isRunning = true
        logger.info("MicProcessor started with format: \(inputFormat)")
    }

    func stop() {
        guard isRunning else { return }
        
        // Remove tap before stopping engine
        engine.mainMixerNode.removeTap(onBus: 0)
        
        // Stop the engine
        engine.stop()
        
        // Disconnect nodes BEFORE detaching (critical!)
        if let unit = isolationUnit {
            engine.disconnectNodeInput(unit)
            engine.disconnectNodeOutput(unit)
            engine.detach(unit)
            isolationUnit = nil
        }
        
        isRunning = false
        outputLevel = 0
        logger.info("MicProcessor stopped")
    }

    // MARK: - Preference loading (call before start())

    func loadPreferences(gainDB: Float, autoAdjust: Bool) {
        makeupGainDB = gainDB
        self.autoAdjust = autoAdjust
    }

    func applyQualityPreset(_ preset: String) {
        let initialIsolation: Float
        switch preset {
        case "light":      initialIsolation = 30
        case "aggressive": initialIsolation = 80
        default:           initialIsolation = 50
        }
        setIsolationLevel(initialIsolation)
    }

    // MARK: - Parameter control (main thread)

    func setIsolationLevel(_ percent: Float) {
        let clamped = min(85, max(15, percent))
        tapIsolation = clamped
        setIsolationParameter(clamped)
        currentIsolation = clamped
    }

    private func setIsolationParameter(_ value: Float) {
        guard let au = isolationUnit?.audioUnit else { return }
        AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, value, 0)
    }

    private func setDevice(_ deviceID: AudioDeviceID, on node: AVAudioIONode) throws {
        guard let au = node.audioUnit else {
            throw NSError(domain: "MicProcessor", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Audio IO node has no underlying audio unit"])
        }
        var id = deviceID
        let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: "MicProcessor", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to select audio device (code \(status))"])
        }
    }

    // MARK: - Tap installation

    private func installTap() {
        let mixerNode = engine.mainMixerNode
        
        // Remove any existing tap first
        mixerNode.removeTap(onBus: 0)
        
        let format = mixerNode.outputFormat(forBus: 0)
        
        // Ensure we have a valid format
        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.error("Invalid mixer output format")
            return
        }
        
        logger.info("Installing tap with format: \(format)")
        
        mixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }
    }

    // Runs on audio thread. Must not allocate or block.
    // nonisolated to opt out of implicit @MainActor isolation.
    private nonisolated func processTap(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let rms = DSP.calculateRMS(samples: channelData, count: frameCount)

        if tapAutoAdjust {
            runAutoAdjust(rms: rms)
        }

        DispatchQueue.main.async { [weak self] in
            self?.outputLevel = rms
        }
    }

    // Proportional controller: target 0.1 RMS, deadband 0.02, step 0.5, range 15-85%.
    // The deadband is applied in RMS space (0.02 = ±20% of the 0.1 target). This prevents
    // jitter without requiring direct manipulation of the isolation parameter range; changes
    // to the isolation parameter only occur when the output level meaningfully deviates from
    // the target, not on every audio callback.
    private nonisolated func runAutoAdjust(rms: Float) {
        let targetRMS: Float = 0.1
        let deadband: Float = 0.02
        let stepSize: Float = 0.5

        let previousIsolation = tapIsolation

        if rms < targetRMS - deadband {
            tapIsolation = max(15, tapIsolation - stepSize)
        } else if rms > targetRMS + deadband {
            tapIsolation = min(85, tapIsolation + stepSize)
        }

        let newIsolation = tapIsolation
        guard newIsolation != previousIsolation else { return }
        DispatchQueue.main.async { [weak self] in
            self?.setIsolationParameter(newIsolation)
            self?.currentIsolation = newIsolation
        }
    }
}
