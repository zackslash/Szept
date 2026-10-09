import Foundation
import AudioToolbox
import Accelerate
import os.log

/// Real-time state for the mic capture callback. Plain final class,
/// mirroring the sharer's CaptureContext (see SystemAudioSharer): the
/// render callback is a bare C function with NO ObjC entry, so the
/// context must not be touchable as an ObjC object. RT rules: the
/// callbacks take NO locks, do NO allocation, and touch NO ObjC runtime.
/// The processor owns the context for the input unit's whole lifetime
/// and disposes the unit before dropping the context, so the callbacks
/// can never observe a dead refCon.
fileprivate final class MicCaptureContext {
    let channels: Int
    /// True when the probed ASBD lacks kAudioFormatFlagIsNonInterleaved:
    /// one buffer, all channels packed (the common interface shape).
    let interleaved: Bool
    /// Frames between successive channel-0 samples in the interleaved
    /// buffer (== channels); 1 in the non-interleaved walk.
    let stride: Int
    let capacityFrames: UInt32 = 4096

    /// Preallocated input list, shaped to the PROBED device format:
    /// interleaved -> a single buffer of `channels` x 4096 frames;
    /// non-interleaved -> one mono buffer per channel. Built ONCE at
    /// build time; the callback only fills it.
    let inListPtr: UnsafeMutableRawPointer
    /// Preallocated output list for the isolation AU's pull: one mono
    /// float32 buffer of 4096 frames (the AU is configured mono in both
    /// scopes, so one buffer is always the right shape).
    let outListPtr: UnsafeMutableRawPointer
    /// Mono scratch the callback deinterleaves channel 0 into (RT:
    /// no allocation), and the meter/chain input.
    let inMono: UnsafeMutablePointer<Float>

    /// Monotonically advancing sample-time stamp for the isolation AU's
    /// render pulls. Advanced by the callback; NO clock calls in RT.
    nonisolated(unsafe) var framePosition: Double = 0
    /// Last isolation AudioUnitRender status (fail-open diagnostics),
    /// logged only in stopLocked AFTER the units are stopped.
    nonisolated(unsafe) var isolationStatus: OSStatus = 0
    /// Last input AudioUnitRender status (same diagnostics discipline).
    nonisolated(unsafe) var renderStatus: OSStatus = 0
    /// Count of input renders clipped to the preallocated capacity.
    nonisolated(unsafe) var overflowCount: Int = 0

    init(asbd: AudioStreamBasicDescription) {
        channels = Int(asbd.mChannelsPerFrame)
        interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        stride = interleaved ? channels : 1
        inMono = .allocate(capacity: 4096)
        let frameBytes = 4096 * MemoryLayout<Float>.size
        let listSize: Int
        if interleaved {
            listSize = MemoryLayout<AudioBufferList>.size
        } else {
            listSize = MemoryLayout<AudioBufferList>.size
                + (channels - 1) * MemoryLayout<AudioBuffer>.stride
        }
        let inDataSize = 4096 * channels * MemoryLayout<Float>.size
        let inTotal = listSize + inDataSize
        inListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: inTotal, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        memset(inListPtr, 0, inTotal)
        let inBuffers = UnsafeMutableAudioBufferListPointer(
            inListPtr.assumingMemoryBound(to: AudioBufferList.self)
        )
        var dataOffset = listSize
        if interleaved {
            // One buffer, all channels interleaved - the device's native
            // delivery shape (AudioUnitRender validates the list against
            // the device format; a mismatch is -50 paramErr).
            inBuffers.count = 1
            inBuffers[0] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(inDataSize),
                mData: inListPtr + dataOffset
            )
        } else {
            inBuffers.count = channels
            for i in 0..<channels {
                inBuffers[i] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frameBytes),
                    mData: inListPtr + dataOffset
                )
                dataOffset += frameBytes
            }
        }
        let outTotal = MemoryLayout<AudioBufferList>.size + frameBytes
        outListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: outTotal, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        memset(outListPtr, 0, outTotal)
        let outBuffers = UnsafeMutableAudioBufferListPointer(
            outListPtr.assumingMemoryBound(to: AudioBufferList.self)
        )
        outBuffers.count = 1
        outBuffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameBytes),
            mData: outListPtr + MemoryLayout<AudioBufferList>.size
        )
    }

    deinit {
        inListPtr.deallocate()
        outListPtr.deallocate()
        inMono.deallocate()
    }
}

/// The mic input callback: a STORED C function pointer, NOT a closure
/// over self (no context capture means no ObjC, no allocation, no
/// locking on the RT thread). refCon is the MicProcessor (same pattern
/// as drainRing's refCon). Renders bus 1 element 0 into the context's
/// preallocated input list, then hands off to processCapture. On
/// AudioUnitRender error: record renderStatus and return noErr - never
/// fail the unit over one bad render.
fileprivate let micInputCallback: AURenderCallback = { refCon, _, inTimeStamp, _, inNumberFrames, _ -> OSStatus in
    let processor = Unmanaged<MicProcessor>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = processor.inputUnit, let context = processor.captureContext else { return noErr }
    // Clamp to the preallocated capacity; count the overflow instead of
    // growing (RT: no allocation).
    var frames = Int(inNumberFrames)
    if frames > Int(context.capacityFrames) {
        frames = Int(context.capacityFrames)
        context.overflowCount += 1
    }
    var renderFlags = AudioUnitRenderActionFlags()
    let list = UnsafeMutablePointer<AudioBufferList>(OpaquePointer(context.inListPtr))
    let status = AudioUnitRender(
        unit, &renderFlags, inTimeStamp, 1, UInt32(frames), list
    )
    if status != noErr {
        context.renderStatus = status
        return noErr
    }
    guard frames > 0 else { return noErr }
    processor.processCapture(frames: frames, timestamp: inTimeStamp)
    return noErr
}

/// The isolation AU's input render callback (SetRenderCallback, input
/// scope, refCon = the processor): copies channel 0 of the capture
/// context's input list into the AU's input list, layout-aware -
/// interleaved stride walk or direct mData[0]. The AU is mono in both
/// scopes, so one destination buffer is always the right shape.
fileprivate let isolationInputCallback: AURenderCallback = { refCon, _, _, _, inNumberFrames, ioData -> OSStatus in
    let processor = Unmanaged<MicProcessor>.fromOpaque(refCon).takeUnretainedValue()
    guard let context = processor.captureContext else { return noErr }
    guard let ioList = ioData, ioList.pointee.mNumberBuffers > 0,
          let dst = ioList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    let inABL = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer<AudioBufferList>(OpaquePointer(context.inListPtr))
    )
    guard inABL.count > 0, let src = inABL[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    let frames = min(Int(inNumberFrames), Int(context.capacityFrames))
    if context.interleaved, context.channels > 1 {
        let stride = context.stride
        var i = 0
        while i < frames {
            dst[i] = src[i * stride]
            i += 1
        }
    } else {
        var i = 0
        while i < frames {
            dst[i] = src[i]
            i += 1
        }
    }
    return noErr
}

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
    // Voice-only mute. Main-thread writes via setVoiceMuted, render thread
    // reads in processCapture; single word, same pattern as tapIsolation.
    // Session-scoped: never persisted anywhere, so a fresh launch always
    // starts audible.
    nonisolated(unsafe) private(set) var voiceMuted = false
    // Latest output RMS. Written only by the render thread, polled by the
    // main-thread meter timer: one word-sized store/load needs no lock and
    // the render thread never dispatches or allocates.
    nonisolated(unsafe) private var meterLevel: Float = 0
    // Diagnostic: total taps since launch, RT-incremented (single word,
    // no allocation, only writer); the meter timer snapshots the total and
    // computes per-window deltas.
    nonisolated(unsafe) private var tapCount = 0

    // MARK: - Output dump diagnostic (szept://dump)
    // RT capture of EXACTLY what drainRing delivers (post-chain,
    // post-mix, post-limiter), written to ~/Desktop/szept-dump.wav by a
    // utility queue. Exists because external readers are TCC-deaf: any
    // SSH-run recorder gets silent zeros for mic-class devices
    // (verified: recording the built-in mic with audible speech in the
    // room returns zeros outside the GUI session), so the only
    // trustworthy remote verifier of delivered audio is the app itself.
    private let dumpCapacity = 48000 * 5
    private let dumpBuffer: UnsafeMutablePointer<Float> = .allocate(capacity: 240_000)
    nonisolated(unsafe) private var dumpArmed = false
    nonisolated(unsafe) private var dumpFilled = 0
    // Optional system-audio mix bus, injected once at init by AppState and
    // never mutated afterwards. Consumed by drainRing (render thread) when
    // system-audio sharing is armed; nil/inactive leaves the render path
    // bit-identical to the unshared pipeline.
    let systemMixBus: SystemMixBus?

    init(systemMixBus: SystemMixBus? = nil) {
        self.systemMixBus = systemMixBus
    }

    /// The capture/render rate of the current start, read by the
    /// system-audio sharer to arm its mix bus servo. Written by start()
    /// only; single-word store, read cross-thread.
    nonisolated(unsafe) var renderSampleRate: Double?

    // MARK: - Meter and process-activity state (main thread only)

    private var meterTimer: Timer?
    // Process activity token held while the pipeline runs (App Nap guard).
    private var activity: NSObjectProtocol?
    // Display-side staleness tracking: when the capture stream stalls the
    // render-side value stops changing and the bar would freeze at the
    // last speech level.
    private var lastRTLevel: Float = -1
    private var meterStaleTicks = 0
    private var meterTick = 0
    private var lastTapRate = -1
    // Snapshot of the RT tap total at the last window close; deltas give
    // the per-window rate without a second writer.
    private var lastTapCount = 0

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
    private(set) var aggregateDeviceID: AudioDeviceID?
    // Offset of the BlackHole member's channels within the aggregate's
    // output channel list (the input sub-device's own output count).
    private var aggregateChannelOffset: UInt32 = 0
    private var aggregateChannelCount: UInt32 = 0

    /// Destroy the aggregate we created, if any. Keeps the invariant that
    /// aggregateDeviceID is non-nil only while the pipeline is running.
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

    // MARK: - Dedicated HAL units (input capture + isolation effect)

    private let logger = Logger(subsystem: "dev.zackslash.Szept", category: "MicProcessor")

    // The mic pipeline has NO AVAudioEngine (invariant I6 below): input
    // capture is a dedicated HALOutput unit pinned to the mic interface,
    // feeding the ring through micInputCallback, and the AUSoundIsolation
    // effect is a dedicated AudioComponentInstance pulled manually from
    // processCapture. The dedicated output unit (below) is unchanged. All
    // IO is HAL units with explicit lifecycles, so the engine's graph
    // assembly and its converter stack are gone entirely.
    //
    // Invariant I1 (deadlock): the mic path no longer contributes ANY
    // client on the default output - the input unit is pinned to the mic
    // interface, and the output unit is pinned to its own target. The
    // sharer's stop-before-destroy ordering is retained regardless (belt
    // and braces; see SystemAudioSharer's I1).
    //
    // Invariant I6 (structural immunity): the app contains ZERO
    // AVAudioEngines; all IO is dedicated HAL units with explicit
    // lifecycles. Default-output changes are therefore structurally
    // invisible to the pipeline - the prod crash class (the engine's
    // unpinned muted output unit re-targeting onto a wide-channel share
    // multi-output and tripping Apple's converter validation) cannot
    // exist here: there is no engine to re-target.

    /// Serializes start()/stop() against each other. The share teardown
    /// stops these units from the sharer's worker queue (invariant I1),
    /// while stop()/start() also run on main (toggleEngine, wake rebuild,
    /// terminate); without the lock the unit/isRunning mutation sections
    /// could interleave across threads. NSLock (not recursive):
    /// start()'s internal failure path calls the UNLOCKED stopLocked(),
    /// never stop().
    private let lifecycleLock = NSLock()

    /// The dedicated HAL input unit (HALOutput, input element enabled,
    /// pinned to the mic interface). Built in startLocked, disposed in
    /// stopLocked. File-accessible for the C callbacks in this file.
    nonisolated(unsafe) fileprivate var inputUnit: AudioComponentInstance?
    /// The dedicated AUSoundIsolation instance, mono float32 in both
    /// scopes, pulled manually by processCapture. Nil = fail-open (the
    /// voice chain runs WITHOUT isolation; logged at start).
    nonisolated(unsafe) fileprivate var isolationAU: AudioComponentInstance?
    /// RT state for micInputCallback (see the context's doc at the top
    /// of the file). Non-nil only while inputUnit is live.
    nonisolated(unsafe) fileprivate var captureContext: MicCaptureContext?

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
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try startLocked()
    }

    /// start() body; caller holds lifecycleLock. The sharer's queue-side
    /// stop (I1 teardown) can no longer interleave with this section's
    /// unit/isRunning mutations.
    private func startLocked() throws {
        guard !isRunning else { return }

        FileLog.log("start: beginning")

        // Bypass never survives a restart: always start un-bypassed (this
        // also restores any pre-bypass isolation/clarity).
        if isBypassed { setBypassed(false) }

        // 1. Resolve the output device (unchanged contract).
        if outputDeviceID == nil {
            outputDeviceID = try AudioDeviceManager.firstBlackHole()?.id
            if outputDeviceID == nil {
                FileLog.log("start: no output device found")
                throw NSError(domain: "MicProcessor", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: "No output device found. Install BlackHole (existential.audio/blackhole) or pick a device in Settings."])
            }
        }
        FileLog.log("start: output device id \(outputDeviceID!)")

        // 2. Private aggregate for the output bridge (unchanged).
        if useAggregateDevice {
            setupAggregateDevice()
        } else {
            // Flag turned off between runs: drop any leftover aggregate.
            destroyAggregateIfNeeded()
        }

        // 3. Resolve the input device: the pinned selection, else the
        // system default input (same resolution and logs as the
        // aggregate's input leg).
        let inputID: AudioDeviceID
        if let pinned = inputDeviceID {
            inputID = pinned
            FileLog.log("start: input device is pinned device id \(pinned)")
        } else {
            do {
                inputID = try AudioDeviceManager.defaultInputDeviceID()
                FileLog.log("start: input device is system default input id \(inputID)")
            } catch {
                FileLog.log("start: no input device: \(error.localizedDescription)")
                destroyAggregateIfNeeded()
                throw NSError(domain: "MicProcessor", code: 20,
                              userInfo: [NSLocalizedDescriptionKey: "No input device found. Connect a microphone or pick another microphone in Settings."])
            }
        }

        // 4. LIGHT settle-check, deliberately NOT the share path's probe:
        // the mic interface is not a device we churn clients on (no pin
        // against post-teardown unstack churn, no shared-member
        // multi-output history), so the poison class behind the share
        // probe's strictness does not apply. Two inputStreamFormat reads
        // 50ms apart, identical and sane, within 500ms, is enough.
        var asbd: AudioStreamBasicDescription?
        var waitedMs = 0
        while waitedMs <= 500 {
            let first = AudioDeviceManager.inputStreamFormat(deviceID: inputID)
            usleep(50_000)
            waitedMs += 50
            let second = AudioDeviceManager.inputStreamFormat(deviceID: inputID)
            if let f = first, let s = second,
               f.mSampleRate == s.mSampleRate,
               f.mChannelsPerFrame == s.mChannelsPerFrame,
               s.mSampleRate > 0, s.mChannelsPerFrame >= 1 {
                asbd = s
                break
            }
        }
        guard let probed = asbd else {
            FileLog.log("start: input format never stabilized within 500ms")
            destroyAggregateIfNeeded()
            throw NSError(domain: "MicProcessor", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: "The microphone is not ready yet. Try starting again in a few seconds."])
        }
        let inputRate = probed.mSampleRate
        let inputChannels = Int(probed.mChannelsPerFrame)
        let inputInterleaved = probed.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        FileLog.log("start: input format \(Int(inputRate)) Hz, \(inputChannels) ch \(inputInterleaved ? "interleaved" : "non-interleaved")")

        // 5. RT context for the input callback, shaped to the PROBED
        // format. The context's interleaved flag follows the CLIENT
        // format below (canonical Float32 non-interleaved) - the buffers
        // the callback renders arrive in the client format's shape.
        let clientASBD = AudioStreamBasicDescription(
            mSampleRate: inputRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(inputChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let context = MicCaptureContext(asbd: clientASBD)
        captureContext = context

        // 6. Build the input unit (input element enabled, output
        // disabled, pinned to the mic interface, CLIENT FORMAT SET,
        // input callback registered). The client format is
        // load-bearing: a format-less input unit's IO runs and its
        // callback fires, but the device's input stream is never
        // configured and every buffer delivers zeros (verified via the
        // in-app dump: 5s of exact zeros with audible speech and the
        // callback sampled live; the AVAudioEngine era worked because
        // the engine set this format internally). The round-10
        // "-10865 rejects client formats" finding was BlackHole-16ch
        // SPECIFIC - the mic accepts the set (verified on-device).
        let newInputUnit = try buildInputUnit(deviceID: inputID, clientFormat: clientASBD)
        inputUnit = newInputUnit

        // 7. Build the isolation AU (mono float32 both scopes, render
        // callback on the input scope). Fail-open: a build failure logs
        // and leaves isolationAU nil - the chain runs WITHOUT isolation
        // rather than failing the start.
        isolationAU = buildIsolationAU(sampleRate: inputRate)
        if let iso = isolationAU {
            FileLog.log("mic: [isolation] armed at \(tapIsolation)")
            AudioUnitSetParameter(iso, 0, kAudioUnitScope_Global, 0, tapIsolation, 0)
        } else {
            FileLog.log("mic: [isolation] unavailable, running WITHOUT isolation (fail-open)")
        }

        // 8. Reset the ring BEFORE any producer/consumer starts (the
        // input callback is the producer; it cannot run before step 9's
        // start). Allocated once, reused forever.
        if ring == nil {
            ring = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        }
        ringRead = 0
        ringWrite = 0

        // Arm the clarity chain with the render rate.
        voiceChain.configure(sampleRate: Float(inputRate))
        renderSampleRate = inputRate

        // 9. Initialize and start the input unit (bracketed; each call is
        // park-capable and logged).
        FileLog.log("mic: [input unit] initializing (park-capable)")
        var st = AudioUnitInitialize(newInputUnit)
        FileLog.log("mic: [input unit] initialized")
        if st != noErr {
            captureContext = nil
            AudioComponentInstanceDispose(newInputUnit)
            inputUnit = nil
            if let iso = isolationAU { AudioUnitUninitialize(iso); AudioComponentInstanceDispose(iso) }
            isolationAU = nil
            destroyAggregateIfNeeded()
            throw AudioDeviceError.queryFailed(st)
        }
        FileLog.log("mic: [input unit] starting (park-capable)")
        st = AudioOutputUnitStart(newInputUnit)
        FileLog.log("mic: [input unit] started")
        if st != noErr {
            AudioUnitUninitialize(newInputUnit)
            AudioComponentInstanceDispose(newInputUnit)
            inputUnit = nil
            captureContext = nil
            if let iso = isolationAU { AudioUnitUninitialize(iso); AudioComponentInstanceDispose(iso) }
            isolationAU = nil
            destroyAggregateIfNeeded()
            throw AudioDeviceError.queryFailed(st)
        }
        FileLog.log("mic: [input unit] started, \(Int(inputRate)) Hz, \(inputChannels) ch, interleaved=\(inputInterleaved)")

        // 10. Feed the target device from the ring (unchanged). If this
        // fails there is no usable output path, so stop rather than run
        // silently.
        do {
            try startOutputUnit(sampleRate: inputRate)
        } catch {
            FileLog.log("start: output unit failed: \(error.localizedDescription)")
            stopLocked()
            throw error
        }
        FileLog.log("start: complete, output unit running")
        startMeterTimer()

        isRunning = true
        // Keep macOS from napping the app while audio flows: App Nap
        // throttles main-thread timers, which would show up as growing
        // meter lag over long sessions. System idle sleep stays allowed;
        // the wake handler rebuilds the pipeline after real sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Szept audio pipeline active"
        )
        logger.notice("MicProcessor started; dedicated HAL input + output units running")
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopLocked()
    }

    /// stop() body; caller holds lifecycleLock. Idempotent: also callable
    /// from the start-failure path, where isRunning is still false but
    /// live units must be torn down.
    private func stopLocked() {
        FileLog.log("stop: tearing down (isRunning=\(isRunning))")

        stopOutputUnit()

        // 2. Stop, uninitialize, and dispose the input unit (bracketed;
        // each call is park-capable and logged).
        if let unit = inputUnit {
            FileLog.log("mic: [input unit] stopping (park-capable)")
            AudioOutputUnitStop(unit)
            FileLog.log("mic: [input unit] stopped")
            FileLog.log("mic: [input unit] uninitializing (park-capable)")
            AudioUnitUninitialize(unit)
            FileLog.log("mic: [input unit] uninitialized")
            FileLog.log("mic: [input unit] disposing (park-capable)")
            AudioComponentInstanceDispose(unit)
            inputUnit = nil
            FileLog.log("mic: [input unit] disposed")
        }

        // 3. Uninitialize and dispose the isolation AU, with the RT
        // diagnostics (logged only now: the unit is stopped, so no
        // concurrent writer remains).
        if let iso = isolationAU {
            if let ctx = captureContext {
                if ctx.isolationStatus != 0 || ctx.overflowCount != 0 || ctx.renderStatus != 0 {
                    FileLog.log("mic: [isolation] renderStatus=\(ctx.renderStatus), isolationStatus=\(ctx.isolationStatus), overflowCount=\(ctx.overflowCount)")
                }
            }
            FileLog.log("mic: [isolation] uninitializing (park-capable)")
            AudioUnitUninitialize(iso)
            FileLog.log("mic: [isolation] disposing (park-capable)")
            AudioComponentInstanceDispose(iso)
            isolationAU = nil
            FileLog.log("mic: [isolation] disposed")
        }
        captureContext = nil

        // Output unit first, then the aggregate it pointed at.
        destroyAggregateIfNeeded()

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
        meterTick = 0
        lastTapRate = -1
        // Snapshot the total now: a stale carry across a restart yields a
        // first-window rate of 0, not garbage.
        lastTapCount = tapCount
        // .common so the timer keeps firing while an NSMenu is tracking:
        // the meter lives inside the open menu popup, where default-mode
        // timers are suspended.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let level = self.meterLevel
            // 1s diagnostic window over the render tap count.
            self.meterTick += 1
            if self.meterTick % 60 == 0 {
                let now = self.tapCount
                self.lastTapRate = now &- self.lastTapCount
                self.lastTapCount = now
            }
            if level != self.lastRTLevel {
                if self.meterStaleTicks >= 18 {
                    FileLog.log("meter: recovered after \(self.meterStaleTicks) stale ticks")
                }
                // Fresh data: track it directly (instant attack). Write
                // outputLevel only beyond a small display hysteresis
                // (the view's own is 0.01).
                self.lastRTLevel = level
                self.meterStaleTicks = 0
                if abs(level - self.outputLevel) > 0.005 { self.outputLevel = level }
            } else {
                self.meterStaleTicks += 1
                if self.meterStaleTicks == 18 {
                    // One line per episode: near-zero rate = true render stall; normal rate = constant raw-input level.
                    let rate = self.lastTapRate < 0 ? "n/a" : "\(self.lastTapRate)/s"
                    FileLog.log("meter: value frozen >300ms (tap rate \(rate))")
                }
                // ~300ms with no new value reads as a stalled stream:
                // decay the bar toward zero and keep it there.
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
        guard let au = isolationAU else { return }
        AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, value, 0)
    }

    // MARK: - Dedicated input unit + isolation AU (builders)

    /// Build the HAL input unit: input element enabled, output element
    /// disabled (aurioTouch / QA1533 pattern), pinned to the mic
    /// interface, input callback registered. NO client format is set:
    /// macOS 26.2's HAL unit rejects client formats on the input element
    /// outright (kAudioUnitErr_PropertyNotWritable, -10865), and none is
    /// needed - the unit delivers the DEVICE'S OWN stream format, the
    /// same one the probe read and the context preallocates for. No
    /// format negotiation: no converter, no validator, nothing for
    /// Apple's render-path validation to trip over. Every mutation is
    /// FileLog-bracketed (park-capable). Failure at any step disposes
    /// what was created before throwing.
    private func buildInputUnit(deviceID: AudioDeviceID, clientFormat: AudioStreamBasicDescription) throws -> AudioComponentInstance {
        FileLog.log("mic: [input unit] finding HALOutput component (park-capable)")
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "MicProcessor", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "HALOutput audio component not found"])
        }
        FileLog.log("mic: [input unit] creating component instance (park-capable)")
        var newUnit: AudioComponentInstance?
        let newStatus = AudioComponentInstanceNew(component, &newUnit)
        FileLog.log("mic: [input unit] component instance created")
        guard newStatus == noErr, let unit = newUnit else {
            throw AudioDeviceError.queryFailed(newStatus)
        }

        // Input-only wiring: enable the input element (scope Input,
        // element 1), disable the output element (scope Output, element
        // 0). The unit therefore contributes NO client on the default
        // output (I1/I6).
        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        FileLog.log("mic: [input unit] enabling input element (park-capable)")
        var st = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioDeviceError.queryFailed(st)
        }
        FileLog.log("mic: [input unit] disabling output element (park-capable)")
        st = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioDeviceError.queryFailed(st)
        }

        var device = deviceID
        FileLog.log("mic: [input unit] pinning device (park-capable)")
        st = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        FileLog.log("mic: [input unit] pin done")
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioDeviceError.queryFailed(st)
        }

        // CLIENT FORMAT (input scope, element 1): configures the device's
        // input stream for this client. Without it the IO cycle runs and
        // the callback fires, but the stream is never configured and every
        // buffer is zeros (see startLocked step 6 note). BlackHole 16ch
        // rejects this set (-10865, round 10) - mic interfaces accept it.
        var cfmt = clientFormat
        FileLog.log("mic: [input unit] setting client format (park-capable)")
        st = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1, &cfmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        FileLog.log("mic: [input unit] client format set: \(st)")
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioDeviceError.queryFailed(st)
        }

        // The input callback, refCon via passUnretained (the processor
        // owns the context and disposes the unit before dropping it).
        var callbackStruct = AURenderCallbackStruct(
            inputProc: micInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        st = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Input, 1, &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioDeviceError.queryFailed(st)
        }
        return unit
    }

    /// Build the AUSoundIsolation instance: mono float32 in BOTH scopes
    /// (the probed rate), render callback on the input scope feeding it
    /// from the capture context, then Initialize. Returns nil on ANY
    /// failure (fail-open: the pipeline runs without isolation), after
    /// disposing whatever was created.
    private func buildIsolationAU(sampleRate: Double) -> AudioComponentInstance? {
        var desc = Self.isolationDescription
        guard let component = AudioComponentFindNext(nil, &desc) else {
            FileLog.log("mic: [isolation] component not found")
            return nil
        }
        FileLog.log("mic: [isolation] creating component instance (park-capable)")
        var newUnit: AudioComponentInstance?
        let newStatus = AudioComponentInstanceNew(component, &newUnit)
        FileLog.log("mic: [isolation] component instance created")
        guard newStatus == noErr, let unit = newUnit else {
            FileLog.log("mic: [isolation] creation failed (\(newStatus))")
            return nil
        }
        // Mono float32, non-interleaved: 4 bytes per frame/packet is one
        // channel's sample.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kLinearPCMFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var st = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard st == noErr else {
            FileLog.log("mic: [isolation] input format rejected (\(st))")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        st = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard st == noErr else {
            FileLog.log("mic: [isolation] output format rejected (\(st))")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        var callbackStruct = AURenderCallbackStruct(
            inputProc: isolationInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        st = AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard st == noErr else {
            FileLog.log("mic: [isolation] render callback rejected (\(st))")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        FileLog.log("mic: [isolation] initializing (park-capable)")
        st = AudioUnitInitialize(unit)
        FileLog.log("mic: [isolation] initialized")
        guard st == noErr else {
            FileLog.log("mic: [isolation] initialize failed (\(st))")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }

    // MARK: - Capture processing (RT, input unit's render thread)

    /// Runs on the input unit's render thread via micInputCallback. Must
    /// not allocate or block. Semantics identical to the old
    /// processTap: meter on the raw input, voice-mute gate, isolation
    /// render (fail-open), voice chain, soft limiter, ring push.
    fileprivate nonisolated func processCapture(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>) {
        guard let context = captureContext else { return }
        let inABL = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>(OpaquePointer(context.inListPtr))
        )
        guard inABL.count > 0, let inData = inABL[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let mono = context.inMono
        if context.interleaved, context.channels > 1 {
            let stride = context.stride
            var i = 0
            while i < frames {
                mono[i] = inData[i * stride]
                i += 1
            }
        } else {
            var i = 0
            while i < frames {
                mono[i] = inData[i]
                i += 1
            }
        }

        // Meter FIRST, on the raw input: while muted the meter stays live
        // and shows the level you WOULD be sending. tapCount keeps ticking
        // too, so the meter-stall diagnostic cannot false-positive.
        let rms = DSP.calculateRMS(samples: mono, count: frames)
        meterLevel = rms
        tapCount &+= 1

        // Voice-only mute: stop BEFORE the chain and the ring. The ring
        // simply runs dry and drainRing zero-fills, so the voice leg
        // becomes digital silence while the system mix (added in drainRing
        // after the fill) keeps flowing. Skipping the chain also saves the
        // discarded work.
        guard !voiceMuted else { return }

        // Isolation render: pull the AU's output (the pull invokes
        // isolationInputCallback on the input scope). Timestamps are the
        // context's monotonically advancing sample counter - NO clock
        // calls in RT. On error: FAIL-OPEN passthrough (the unprocessed
        // mono signal continues down the chain) and record the status.
        var out = mono
        if let iso = isolationAU {
            context.framePosition += Double(frames)
            var ts = AudioTimeStamp()
            ts.mSampleTime = context.framePosition
            ts.mFlags = .sampleTimeValid
            var renderFlags = AudioUnitRenderActionFlags()
            let outList = UnsafeMutablePointer<AudioBufferList>(OpaquePointer(context.outListPtr))
            let status = AudioUnitRender(iso, &renderFlags, &ts, 0, UInt32(frames), outList)
            if status == noErr {
                let outABL = UnsafeMutableAudioBufferListPointer(outList)
                if let rendered = outABL[0].mData?.assumingMemoryBound(to: Float.self) {
                    out = rendered
                }
            } else {
                context.isolationStatus = status
            }
        }

        // Post-chain signal feeds the ring.
        voiceChain.process(out, count: frames)
        DSP.applySoftLimiter(samples: out, count: frames, threshold: 0.7)
        pushToRing(samples: out, count: frames)
    }

    /// Main thread. Mutes only the VOICE leg; system-audio sharing (if
    /// active) keeps flowing to the call.
    func setVoiceMuted(_ on: Bool) {
        guard on != voiceMuted else { return }
        voiceMuted = on
        FileLog.log(on ? "voice: muted" : "voice: unmuted")
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
        // the user never picked one. The input unit gets the same resolution.
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
        AudioDeviceManager.setNominalSampleRate(deviceID: deviceID, to: rate, logPrefix: "output")
    }

    private func deviceSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        AudioDeviceManager.nominalSampleRate(deviceID: deviceID)
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
        // System-audio mix point. This runs in the OUTPUT-UNIT render path
        // (drainRing), after the sample/zero-fill loops, NOT in
        // processCapture/pushToRing (the mic producer): system audio must
        // bypass the entire mic filter chain (isolation/clarity/limiter)
        // and land on top of the already-processed voice. Only when frames
        // were actually mixed do we re-limit: the mic leg is limited at 0.7
        // and the system leg sits at 0.8, so the sum can reach ~1.8; the
        // post-mix knee at 0.85 tucks those peaks while remaining an exact
        // identity below it. The knee also applies to mic peaks in
        // (0.85, 1.0) while sharing with silent system audio - an
        // intentional consistent ceiling either way.
        if let bus = systemMixBus, bus.isActive, bus.readMixing(into: list, frames: frames) {
            for buffer in list {
                if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    DSP.applySoftLimiter(samples: data, count: frames, threshold: 0.85)
                }
            }
        }

        // Output dump: capture ch0 of the FINAL delivered samples (RT:
        // fixed-capacity memcpy only; no allocation, no locking).
        if dumpArmed, let data = list[0].mData?.assumingMemoryBound(to: Float.self) {
            let room = dumpCapacity - dumpFilled
            if room > 0 {
                let take = min(frames, room)
                dumpBuffer.advanced(by: dumpFilled).update(from: data, count: take)
                dumpFilled += take
                if dumpFilled >= dumpCapacity { dumpArmed = false }
            } else {
                dumpArmed = false
            }
        }

        // Release: finish reading samples before advancing the read index.
        OSMemoryBarrier()
        ringRead = (ringRead + n) % ringCapacity
    }

    /// Arm the output dump (szept://dump). The render thread captures 5s
    /// of delivered audio; a utility queue writes the WAV afterward.
    /// Main thread only.
    func armOutputDump() {
        guard isRunning else {
            FileLog.log("mic: [dump] ignored, engine not running")
            return
        }
        dumpFilled = 0
        dumpArmed = true
        FileLog.log("mic: [dump] armed (5s)")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.5) { [weak self] in
            guard let self else { return }
            let filled = self.dumpFilled
            self.dumpArmed = false
            guard filled > 0 else {
                FileLog.log("mic: [dump] nothing captured (engine stopped?)")
                return
            }
            var sumSq: Double = 0
            for i in 0..<filled { let v = Double(self.dumpBuffer[i]); sumSq += v * v }
            let rms = (sumSq / Double(filled)).squareRoot()
            var peak: Float = 0
            for i in 0..<filled { let a = abs(self.dumpBuffer[i]); if a > peak { peak = a } }
            self.writeDumpWav(frames: filled)
            FileLog.log("mic: [dump] wrote \(filled) frames, rms \(String(format: "%.4f", rms)), peak \(String(format: "%.4f", peak))")
        }
    }

    /// Write the dump buffer as a mono 16-bit WAV. Utility queue.
    private func writeDumpWav(frames: Int) {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
        let dataBytes = UInt32(frames * 2)
        var wav = Data()
        wav.append(contentsOf: Data("RIFF".utf8))
        wav.append(contentsOf: le32(36 + dataBytes))
        wav.append(contentsOf: Data("WAVE".utf8))
        wav.append(contentsOf: Data("fmt ".utf8))
        wav.append(contentsOf: le32(16)); wav.append(contentsOf: le16(1)); wav.append(contentsOf: le16(1))
        wav.append(contentsOf: le32(48000)); wav.append(contentsOf: le32(96000))
        wav.append(contentsOf: le16(2)); wav.append(contentsOf: le16(16))
        wav.append(contentsOf: Data("data".utf8)); wav.append(contentsOf: le32(dataBytes))
        for i in 0..<frames {
            let v = Int16(max(-32767, min(32767, dumpBuffer[i] * 32767)))
            wav.append(contentsOf: le16(UInt16(bitPattern: v)))
        }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/szept-dump.wav")
        do {
            try wav.write(to: url)
        } catch {
            FileLog.log("mic: [dump] write failed: \(error.localizedDescription)")
        }
    }
}
