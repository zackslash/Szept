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
    private(set) var isMuted: Bool = false
    private(set) var isBypassed: Bool = false
    // Pre-bypass state for exact restore; nil while not bypassed.
    private var bypassedIsolation: Float?
    private var bypassedClarity: ClarityLevel?

    var autoAdjust: Bool = false {
        didSet { tapAutoAdjust = autoAdjust }
    }

    // MARK: - Audio thread state (read from callbacks; nonisolated(unsafe))

    nonisolated(unsafe) private var tapAutoAdjust: Bool = false
    nonisolated(unsafe) private var tapIsolation: Float = 50
    nonisolated(unsafe) private var tapMuted: Bool = false

    // MARK: - Clarity ("Broadcast Voice")

    private let voiceChain = VoiceChain()

    // MARK: - Device routing (set before start())

    var inputDeviceID: AudioDeviceID?
    var outputDeviceID: AudioDeviceID?

    // MARK: - AVAudioEngine

    private var engine = AVAudioEngine()
    private var isolationUnit: AVAudioUnitEffect?
    private let logger = Logger(subsystem: "dev.kocheck.Szept", category: "MicProcessor")

    // MARK: - Dedicated output unit (owned by us, invisible to the engine)
    //
    // AVAudioEngine owns its output unit's device selection and resets it
    // during graph assembly, so the engine's output can never be trusted to
    // reach BlackHole. The engine's mixer is muted (it exists only to pull
    // input through the isolation AU), and this separate HAL output unit
    // feeds the target device from a ring buffer filled by the tap. The
    // engine's device pin is deliberately NOT set: if it ever stuck, the
    // engine would write digital zeros into BlackHole alongside our voice.

    private var outputUnit: AudioComponentInstance?
    private var ring: UnsafeMutablePointer<Float>?
    private let ringCapacity = 1 << 15          // ~0.7 s at 48 kHz
    nonisolated(unsafe) private var ringWrite: Int = 0
    nonisolated(unsafe) private var ringRead: Int = 0

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

        FileLog.log("start: beginning")

        // Mute and bypass never survive a restart: always start unmuted and
        // un-bypassed (this also restores any pre-bypass isolation/clarity).
        if isMuted { setMuted(false) }
        if isBypassed { setBypassed(false) }

        // Always create a fresh engine to avoid state issues
        engine = AVAudioEngine()
        isolationUnit = nil

        if outputDeviceID == nil {
            outputDeviceID = try AudioDeviceManager.firstBlackHole()?.id
            if outputDeviceID == nil {
                FileLog.log("start: no output device found")
                throw NSError(domain: "MicProcessor", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: "No output device found. Install BlackHole (existential.audio/blackhole) or pick a device in Settings."])
            }
        }
        FileLog.log("start: output device id \(outputDeviceID!)")

        do {
            if let id = inputDeviceID {
                try setDevice(id, on: engine.inputNode)
                FileLog.log("start: input device pinned to \(id)")
            }
        } catch {
            FileLog.log("start: input device set failed: \(error.localizedDescription)")
            isolationUnit = nil
            throw error
        }

        let unit = AVAudioUnitEffect(audioComponentDescription: Self.isolationDescription)
        isolationUnit = unit

        engine.attach(unit)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            FileLog.log("start: invalid input format")
            engine.detach(unit)
            isolationUnit = nil
            throw NSError(domain: "MicProcessor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid audio input format"])
        }
        FileLog.log("start: input format \(inputFormat)")

        let mixerNode = engine.mainMixerNode
        engine.connect(engine.inputNode, to: unit, format: inputFormat)
        engine.connect(unit, to: mixerNode, format: inputFormat)
        engine.connect(mixerNode, to: engine.outputNode, format: nil)

        // The engine's own output must never be audible. It exists only to
        // keep the graph rendering; all real output goes through our own
        // output unit below.
        mixerNode.outputVolume = 0

        setIsolationParameter(tapIsolation)

        // Arm the clarity chain with the render rate; the level itself is
        // picked up by the render thread at the first buffer.
        voiceChain.configure(sampleRate: Float(inputFormat.sampleRate))

        // Reset the ring before the engine starts so the tap (producer)
        // never races the reset. Allocated once, reused forever.
        if ring == nil {
            ring = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        }
        ringRead = 0
        ringWrite = 0

        // The tap sits on the isolation unit (pre-mute) so the ring receives
        // the processed signal regardless of where the engine routes its
        // (silent) output.
        installTap(on: unit, format: unit.outputFormat(forBus: 0))

        engine.prepare()
        do {
            try engine.start()
        } catch {
            FileLog.log("start: engine.start failed: \(error.localizedDescription)")
            unit.removeTap(onBus: 0)
            engine.detach(unit)
            isolationUnit = nil
            throw error
        }
        FileLog.log("start: engine started (muted)")

        // Feed the target device from the ring. If this fails there is no
        // usable output path, so stop rather than run silently.
        do {
            try startOutputUnit(sampleRate: inputFormat.sampleRate)
        } catch {
            FileLog.log("start: output unit failed: \(error.localizedDescription)")
            stop()
            throw error
        }
        FileLog.log("start: complete, output unit running")

        isRunning = true
        logger.notice("MicProcessor started; engine muted, dedicated output unit running")
    }

    func stop() {
        // Idempotent: also callable from the start-failure path, where
        // isRunning is still false but a live engine must be torn down.
        FileLog.log("stop: tearing down (isRunning=\(isRunning))")

        stopOutputUnit()

        isolationUnit?.removeTap(onBus: 0)
        engine.stop()

        if let unit = isolationUnit {
            engine.disconnectNodeInput(unit)
            engine.disconnectNodeOutput(unit)
            engine.detach(unit)
            isolationUnit = nil
        }

        isRunning = false
        outputLevel = 0
        logger.notice("MicProcessor stopped")
    }

    // MARK: - Preference loading (call before start())

    func loadPreferences(autoAdjust: Bool) {
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
        // If the level changes during an A/B bypass, the pending restore must
        // land on the NEW value, not the stale pre-bypass one.
        if isBypassed { bypassedIsolation = clamped }
    }

    func setClarity(_ level: ClarityLevel) {
        voiceChain.setClarity(level)
        // Same for clarity chosen during a bypass: restore the NEW level.
        if isBypassed { bypassedClarity = level }
    }

    // MARK: - Mute + A/B bypass (main thread)

    // Broadcast-console style mute: the engine keeps running and the meter
    // stays live, but the ring (and therefore BlackHole) receives silence.
    // Mute is never persisted; the processor always starts unmuted.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        tapMuted = muted
        FileLog.log("mute: \(muted ? "on" : "off")")
    }

    // A/B bypass: momentarily drop isolation to the wet floor (15, the
    // existing clamp minimum) and suspend the clarity chain, so the user can
    // compare processed vs raw. The previous isolation and clarity are stored
    // and restored exactly; the temporary values are never written to
    // currentIsolation or persisted anywhere.
    func setBypassed(_ bypassed: Bool) {
        guard bypassed != isBypassed else { return }
        if bypassed {
            isBypassed = true
            bypassedIsolation = tapIsolation
            bypassedClarity = voiceChain.currentLevel
            tapIsolation = 15
            setIsolationParameter(15)
            voiceChain.setClarity(.off)
            FileLog.log("bypass: on (isolation \(bypassedIsolation.map(String.init(_:)) ?? "?"), clarity \(bypassedClarity?.rawValue ?? "off"))")
        } else {
            isBypassed = false
            if let iso = bypassedIsolation {
                tapIsolation = iso
                setIsolationParameter(iso)
            }
            if let clarity = bypassedClarity {
                voiceChain.setClarity(clarity)
            }
            bypassedIsolation = nil
            bypassedClarity = nil
            FileLog.log("bypass: off")
        }
    }

    private func setIsolationParameter(_ value: Float) {
        guard let au = isolationUnit?.audioUnit else { return }
        AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, value, 0)
    }

    // MARK: - Device selection

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

    // MARK: - Tap (producer)

    private func installTap(on node: AVAudioNode, format: AVAudioFormat) {
        node.removeTap(onBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            FileLog.log("tap: invalid format \(format)")
            return
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }
    }

    // Runs on the engine's render thread. Must not allocate or block.
    private nonisolated func processTap(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Meter the REAL samples first so the level stays live while muted
        // (console-style monitoring). Then, if muted, silence the buffer so
        // the ring (and BlackHole) receive zeros; the push still happens to
        // keep ring timing and backlog behavior consistent.
        let rms = DSP.calculateRMS(samples: channelData, count: frameCount)
        if tapMuted {
            for i in 0..<frameCount { channelData[i] = 0 }
        } else {
            // Clarity lift runs on the processed signal before it reaches the
            // ring; metering reads the post-isolation audio.
            voiceChain.process(channelData, count: frameCount)
        }

        pushToRing(samples: channelData, count: frameCount)

        if tapAutoAdjust {
            runAutoAdjust(rms: rms)
        }
        DispatchQueue.main.async { [weak self] in
            self?.outputLevel = rms
        }
    }

    private nonisolated func pushToRing(samples: UnsafePointer<Float>, count: Int) {
        guard let ring else { return }
        let available = (ringCapacity + ringRead - ringWrite - 1 + ringCapacity) % ringCapacity
        let n = min(count, available)
        for i in 0..<n {
            ring[(ringWrite + i) % ringCapacity] = samples[i]
        }
        // Release: publish the samples before the write index.
        OSMemoryBarrier()
        ringWrite = (ringWrite + n) % ringCapacity
    }

    // MARK: - Auto-adjust (retired from UI, kept inert)

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

    // MARK: - Dedicated output unit (consumer)

    private func startOutputUnit(sampleRate: Double) throws {
        guard let deviceID = outputDeviceID else {
            throw NSError(domain: "MicProcessor", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "No output device selected"])
        }

        // Match the device's nominal rate to the engine input rate so the
        // ring never needs resampling. Best effort; then read back the
        // device's actual rate and use THAT for the stream format.
        alignDeviceSampleRate(deviceID, to: sampleRate)
        let actualRate = deviceSampleRate(deviceID) ?? sampleRate
        FileLog.log("output: engine rate \(sampleRate), device rate \(actualRate)")

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "MicProcessor", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "HAL output unit not available"])
        }

        var instance: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let au = instance else {
            throw NSError(domain: "MicProcessor", code: 16,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create output unit (code \(status))"])
        }

        var deviceId = deviceID
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceId,
                                      UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            FileLog.log("output: device set failed (\(status))")
            AudioComponentInstanceDispose(au)
            throw NSError(domain: "MicProcessor", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: "Output unit rejected the device (code \(status))"])
        }

        // 2ch non-interleaved float32: bytes-per-frame/packet describe one
        // channel's sample (4 bytes), not a stereo frame (8).
        var asbd = AudioStreamBasicDescription(
            mSampleRate: actualRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kLinearPCMFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0, &asbd,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            FileLog.log("output: stream format rejected (\(status))")
            AudioComponentInstanceDispose(au)
            throw NSError(domain: "MicProcessor", code: 18,
                          userInfo: [NSLocalizedDescriptionKey: "Output unit rejected stream format (code \(status))"])
        }

        var callback = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) in
                let processor = Unmanaged<MicProcessor>.fromOpaque(inRefCon).takeUnretainedValue()
                processor.drainRing(into: ioData, frames: Int(inNumberFrames))
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &callback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            FileLog.log("output: render callback rejected (\(status))")
            AudioComponentInstanceDispose(au)
            throw NSError(domain: "MicProcessor", code: 19,
                          userInfo: [NSLocalizedDescriptionKey: "Could not set render callback (code \(status))"])
        }

        status = AudioUnitInitialize(au)
        guard status == noErr else {
            FileLog.log("output: initialize failed (\(status))")
            AudioComponentInstanceDispose(au)
            throw NSError(domain: "MicProcessor", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "Could not initialize output unit (code \(status))"])
        }

        status = AudioOutputUnitStart(au)
        guard status == noErr else {
            FileLog.log("output: start failed (\(status))")
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            throw NSError(domain: "MicProcessor", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start output unit (code \(status))"])
        }

        outputUnit = au
    }

    private func stopOutputUnit() {
        if let au = outputUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            outputUnit = nil
            FileLog.log("output: unit stopped and disposed")
        }
    }

    private func alignDeviceSampleRate(_ deviceID: AudioDeviceID, to rate: Double) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        let size = UInt32(MemoryLayout<Double>.size)
        let status = withUnsafePointer(to: &value) { ptr in
            AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, ptr)
        }
        if status != noErr {
            FileLog.log("output: nominal rate set returned \(status) (continuing)")
        }
    }

    private func deviceSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    // Runs on the output unit's render thread. Must not allocate or block.
    private nonisolated func drainRing(into ioData: UnsafeMutablePointer<AudioBufferList>?, frames: Int) {
        guard let ioData else { return }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        guard let ring else {
            for buffer in list { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return
        }

        // Acquire: observe the samples before trusting the write index.
        let writeIndex = ringWrite
        OSMemoryBarrier()
        let available = (ringCapacity + writeIndex - ringRead) % ringCapacity
        let n = min(frames, available)

        for i in 0..<n {
            let sample = ring[(ringRead + i) % ringCapacity]
            for buffer in list {
                if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    data[i] = sample
                }
            }
        }
        for i in n..<frames {
            for buffer in list {
                if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    data[i] = 0
                }
            }
        }
        ringRead = (ringRead + n) % ringCapacity
    }
}
