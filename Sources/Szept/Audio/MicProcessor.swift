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
    private(set) var isBypassed: Bool = false
    // Pre-bypass state for exact restore; nil while not bypassed.
    private var bypassedIsolation: Float?
    private var bypassedClarity: ClarityLevel?

    // MARK: - Audio thread state (read from callbacks; nonisolated(unsafe))

    nonisolated(unsafe) private var tapIsolation: Float = 50
    // Latest output RMS. Written only by the render thread, polled by the
    // main-thread meter timer: one word-sized store/load needs no lock and
    // the render thread never dispatches or allocates.
    nonisolated(unsafe) private var meterLevel: Float = 0

    // MARK: - Meter and process-activity state (main thread only)

    private var meterTimer: Timer?
    // Process activity token held while the engine runs (App Nap guard).
    private var activity: NSObjectProtocol?
    // Display-side staleness tracking: when the capture stream stalls the
    // render-side value stops changing and the bar would freeze at the
    // last speech level.
    private var lastRTLevel: Float = -1
    private var meterStaleTicks = 0

    // MARK: - Clarity ("Broadcast Voice")

    private let voiceChain = VoiceChain()

    // MARK: - Device routing (set before start())

    var inputDeviceID: AudioDeviceID?
    var outputDeviceID: AudioDeviceID?

    // MARK: - Aggregate device (drift-free output bridge)

    // The mic interface and BlackHole run on unsynchronised clocks, so an
    // SPSC ring bridging them drifts and blips. When enabled and both UIDs
    // resolve, a private aggregate (input as clock master) carries the
    // output instead; any aggregate failure falls back to direct BlackHole
    // routing and never fails a start.
    private var aggregateDeviceID: AudioDeviceID?
    // Offset of the BlackHole member's channels within the aggregate's
    // output channel list (the input sub-device's own output count).
    private var aggregateChannelOffset: UInt32 = 0
    private var aggregateChannelCount: UInt32 = 0

    /// Destroy the aggregate we created, if any. Keeps the invariant that
    /// aggregateDeviceID is non-nil only while the engine is running.
    private func destroyAggregateIfNeeded() {
        if let id = aggregateDeviceID {
            aggregateDeviceID = nil
            aggregateChannelOffset = 0
            aggregateChannelCount = 0
            AudioDeviceManager.destroyAggregateDevice(id: id)
        }
    }

    /// Preference-backed drift-fix switch (default on). Main thread only.
    /// SettingsView writes the defaults key directly.
    private var useAggregateDevice: Bool {
        UserDefaults.standard.object(forKey: "useAggregateDevice") as? Bool ?? true
    }

    // MARK: - AVAudioEngine

    private var engine = AVAudioEngine()
    private var isolationUnit: AVAudioUnitEffect?
    private let logger = Logger(subsystem: "dev.zackslash.Szept", category: "MicProcessor")

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

        // Bypass never survives a restart: always start un-bypassed (this
        // also restores any pre-bypass isolation/clarity).
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

        if useAggregateDevice {
            setupAggregateDevice()
        } else {
            // Flag turned off between runs: drop any leftover aggregate.
            destroyAggregateIfNeeded()
        }

        do {
            if let id = inputDeviceID {
                try setDevice(id, on: engine.inputNode)
                FileLog.log("start: input device pinned to \(id)")
            }
        } catch {
            FileLog.log("start: input device set failed: \(error.localizedDescription)")
            destroyAggregateIfNeeded()
            isolationUnit = nil
            throw error
        }

        let unit = AVAudioUnitEffect(audioComponentDescription: Self.isolationDescription)
        isolationUnit = unit

        engine.attach(unit)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            FileLog.log("start: invalid input format")
            destroyAggregateIfNeeded()
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

        // Arm the clarity chain with the render rate.
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
            destroyAggregateIfNeeded()
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
        startMeterTimer()

        isRunning = true
        // Keep macOS from napping the app while audio flows: App Nap
        // throttles main-thread timers, which would show up as growing
        // meter lag over long sessions. System idle sleep stays allowed;
        // the wake handler rebuilds the engine after real sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Szept audio pipeline active"
        )
        logger.notice("MicProcessor started; engine muted, dedicated output unit running")
    }

    func stop() {
        // Idempotent: also callable from the start-failure path, where
        // isRunning is still false but a live engine must be torn down.
        FileLog.log("stop: tearing down (isRunning=\(isRunning))")

        stopOutputUnit()

        // Output unit first, then the aggregate it pointed at.
        destroyAggregateIfNeeded()

        isolationUnit?.removeTap(onBus: 0)
        engine.stop()

        if let unit = isolationUnit {
            engine.disconnectNodeInput(unit)
            engine.disconnectNodeOutput(unit)
            engine.detach(unit)
            isolationUnit = nil
        }

        isRunning = false
        stopMeterTimer()
        if let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
        outputLevel = 0
        logger.notice("MicProcessor stopped")
    }

    // MARK: - Metering

    private func startMeterTimer() {
        // Clear any pre-stop value so a restart cannot flash it for one tick.
        meterLevel = 0
        lastRTLevel = -1
        meterStaleTicks = 0
        // .common so the timer keeps firing while an NSMenu is tracking:
        // the meter lives inside the open menu popup, where default-mode
        // timers are suspended.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let level = self.meterLevel
            if level != self.lastRTLevel {
                // Fresh data: track it directly (instant attack). Write
                // outputLevel only beyond a small display hysteresis
                // (the view's own is 0.01).
                self.lastRTLevel = level
                self.meterStaleTicks = 0
                if abs(level - self.outputLevel) > 0.005 { self.outputLevel = level }
            } else {
                self.meterStaleTicks += 1
                // Periodic probe (1s): a live stream that repeats bit-identical values recovers.
                if self.meterStaleTicks % 60 == 0 { self.lastRTLevel = -1 }
                // ~300ms with no new value reads as a stalled stream:
                // decay the bar toward zero instead of freezing it.
                if self.meterStaleTicks >= 18 {
                    if self.outputLevel > 0.001 {
                        self.outputLevel *= 0.8
                    } else if self.outputLevel != 0 {
                        self.outputLevel = 0
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    func applyQualityPreset(_ preset: String) {
        let isolation: Float
        switch preset {
        case "light":      isolation = 30
        case "aggressive": isolation = 80
        default:           isolation = 50
        }
        // During bypass, a strength change updates what is restored on
        // bypass-off, never the live floor.
        if isBypassed {
            bypassedIsolation = isolation
            return
        }
        tapIsolation = isolation
        setIsolationParameter(isolation)
    }

    // MARK: - Parameter control (main thread)

    func setClarity(_ level: ClarityLevel) {
        voiceChain.setClarity(level)
        // Same for clarity chosen during a bypass: restore the NEW level.
        if isBypassed { bypassedClarity = level }
    }

    // MARK: - A/B bypass (main thread)

    // A/B bypass invariant: the live isolation and clarity are stored on
    // bypass-on and restored exactly on bypass-off, never persisted.
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

        // Post-chain signal feeds both the ring and the meter.
        voiceChain.process(channelData, count: frameCount)
        DSP.applySoftLimiter(samples: channelData, count: frameCount, threshold: 0.7)

        pushToRing(samples: channelData, count: frameCount)

        let rms = DSP.calculateRMS(samples: channelData, count: frameCount)

        meterLevel = rms
    }

    private nonisolated func pushToRing(samples: UnsafePointer<Float>, count: Int) {
        guard let ring else { return }
        let readIndex = ringRead
        // Acquire: observe the samples before trusting the read index.
        OSMemoryBarrier()
        let available = (ringCapacity + readIndex - ringWrite - 1 + ringCapacity) % ringCapacity
        let n = min(count, available)
        for i in 0..<n {
            ring[(ringWrite + i) % ringCapacity] = samples[i]
        }
        // Release: publish the samples before the write index.
        OSMemoryBarrier()
        ringWrite = (ringWrite + n) % ringCapacity
    }

    // MARK: - Dedicated output unit (consumer)

    /// Build the private aggregate for this start when both device UIDs
    /// resolve. Never throws: on any failure we log, destroy what we made,
    /// and leave aggregateDeviceID nil so startOutputUnit falls back to
    /// direct BlackHole routing.
    private func setupAggregateDevice() {
        destroyAggregateIfNeeded()
        guard let outputID = outputDeviceID else { return }

        // Input leg: the pinned device, or the system default input when
        // the user never picked one. The engine itself stays unpinned.
        let inputID: AudioDeviceID
        if let pinned = inputDeviceID {
            inputID = pinned
            FileLog.log("aggregate: input leg is pinned device id \(pinned)")
        } else {
            do {
                inputID = try AudioDeviceManager.defaultInputDeviceID()
                FileLog.log("aggregate: input leg is system default input id \(inputID)")
            } catch {
                FileLog.log("aggregate: skipped, no default input device: \(error.localizedDescription)")
                return
            }
        }

        guard let inputUID = AudioDeviceManager.deviceUID(for: inputID) else {
            FileLog.log("aggregate: skipped, input device UID lookup failed")
            return
        }
        guard let outputUID = AudioDeviceManager.deviceUID(for: outputID) else {
            FileLog.log("aggregate: skipped, output device UID lookup failed")
            return
        }
        do {
            let id = try AudioDeviceManager.createAggregateDevice(
                inputDeviceUID: inputUID, outputDeviceUID: outputUID
            )
            // Validate the aggregate's output layout: our stereo client
            // must map onto the BlackHole member, whose channels begin at
            // the offset given by the input leg's own output count.
            let aggregateOutputs = AudioDeviceManager.outputChannelCount(deviceID: id)
            let offset = UInt32(AudioDeviceManager.outputChannelCount(deviceID: inputID))
            guard aggregateOutputs >= 2, offset + 2 <= UInt32(aggregateOutputs) else {
                AudioDeviceManager.destroyAggregateDevice(id: id)
                FileLog.log("aggregate: unusable channel layout (aggregate outputs \(aggregateOutputs), BlackHole offset \(offset)), falling back to direct routing")
                return
            }
            aggregateDeviceID = id
            aggregateChannelOffset = offset
            aggregateChannelCount = UInt32(aggregateOutputs)
        } catch {
            FileLog.log("aggregate: creation failed, falling back to direct routing: \(error.localizedDescription)")
            aggregateDeviceID = nil
        }
    }

    /// Build, configure, and start the dedicated HAL output unit against
    /// one device. Every internal failure path disposes the instance before
    /// throwing.
    private func buildOutputUnit(deviceID: AudioDeviceID, sampleRate: Double, channelOffset: UInt32?, deviceChannelCount: UInt32? = nil) throws -> AudioComponentInstance {
        // Match the device's nominal rate to the engine input rate so the
        // ring never needs resampling. Best effort; the stream format then
        // uses the ENGINE/ring rate we actually feed, not the device's
        // read-back rate (a mismatch would make the device consume the ring
        // at the wrong speed). Skipped for the aggregate: its nominal rate
        // follows the clock master, and setting it fails and only pollutes
        // logs.
        if channelOffset == nil {
            alignDeviceSampleRate(deviceID, to: sampleRate)
        }
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

        // Aggregate target: map our stereo client onto the BlackHole
        // member's channels. Per AudioUnitProperties.h the map has one
        // entry per DESTINATION (device) channel, each holding a SOURCE
        // (client) channel index, with -1 silencing that destination
        // channel. BlackHole's channels begin at the offset given by the
        // input leg's own output count.
        if let offset = channelOffset, let deviceChannels = deviceChannelCount {
            var channelMap = [Int32](repeating: -1, count: Int(deviceChannels))
            channelMap[Int(offset)] = 0
            channelMap[Int(offset) + 1] = 1
            let mapSize = UInt32(MemoryLayout<Int32>.size * channelMap.count)
            status = channelMap.withUnsafeMutableBufferPointer { buffer in
                AudioUnitSetProperty(au, kAudioOutputUnitProperty_ChannelMap,
                                      kAudioUnitScope_Output, 0,
                                      buffer.baseAddress, mapSize)
            }
            guard status == noErr else {
                FileLog.log("output: aggregate channel map rejected (\(status))")
                AudioComponentInstanceDispose(au)
                throw NSError(domain: "MicProcessor", code: 22,
                              userInfo: [NSLocalizedDescriptionKey: "Output unit rejected the aggregate channel map (code \(status))"])
            }
        }

        // 2ch non-interleaved float32: bytes-per-frame/packet describe one
        // channel's sample (4 bytes), not a stereo frame (8).
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
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

        return au
    }

    /// Start the dedicated output unit. Prefers the aggregate (one clock,
    /// no drift); if the aggregate path fails at ANY step, the aggregate is
    /// destroyed and the whole unit is rebuilt once against the direct
    /// output device. Only a direct-path failure propagates to start().
    private func startOutputUnit(sampleRate: Double) throws {
        if let aggregateID = aggregateDeviceID {
            FileLog.log("output: routing to aggregate id \(aggregateID)")
            do {
                outputUnit = try buildOutputUnit(
                    deviceID: aggregateID, sampleRate: sampleRate,
                    channelOffset: aggregateChannelOffset,
                    deviceChannelCount: aggregateChannelCount
                )
                return
            } catch {
                FileLog.log("aggregate: output unit rejected, falling back to direct routing: \(error.localizedDescription)")
                aggregateDeviceID = nil
                AudioDeviceManager.destroyAggregateDevice(id: aggregateID)
            }
        }
        guard let directID = outputDeviceID else {
            throw NSError(domain: "MicProcessor", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "No output device selected"])
        }
        outputUnit = try buildOutputUnit(deviceID: directID, sampleRate: sampleRate, channelOffset: nil)
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
        // Release: finish reading samples before advancing the read index.
        OSMemoryBarrier()
        ringRead = (ringRead + n) % ringCapacity
    }
}
