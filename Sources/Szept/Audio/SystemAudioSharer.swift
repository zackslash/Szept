import Foundation
import CoreAudio

/// Owns the system-audio sharing session: a visible multi-output device
/// (speakers + BlackHole 16ch) that becomes the system default output, a
/// raw HAL input IOProc reading BlackHole back, and the mix bus
/// feeding that audio into the mic render path (post-filters, by design).
///
/// Session-scoped: never persisted, never auto-enabled. Sharing is always
/// OFF across launches; only the previous-output UID is saved, as
/// operational state for crash recovery.
///
/// Deadlock invariant (I1): the mic path contributes NO client on the
/// default output - its input IOProc targets the mic interface and its
/// output unit is pinned to its own target - and the share capture side
/// contributes NO default-output client either (a raw input IOProc with
/// no render graph). The stop-before-destroy ordering is therefore
/// retained only as belt and braces. Historically both sides were
/// implicit default-output clients (the unpinned mic engine's muted
/// output unit followed the default output), and the teardown had to
/// stop the mic BEFORE destroying the multi-output (destroying a device
/// an audio unit still references can deadlock a teardown against a
/// wedged HAL plugin).
///
/// Hang invariant (I5): no HAL mutation API is ever called on main
/// once launch cleanup has run (cleanupStaleDevices is the sanctioned
/// pre-any-audio-client exception - it runs before the lifecycle
/// observer and any audio client exists). Every one of the mutation APIs can park indefinitely
/// (dispatch_sync onto an IO queue that a device reconfiguration
/// holds): hang #2 was
/// inputNode.outputFormat(forBus: 0) parking main after our own pin.
/// Therefore both enable and disable do their HAL work on a
/// dedicated worker queue (shareQueue), main only publishes state, and an
/// 8s watchdog converts a parked worker into a latched "stuck" state
/// (code 37) recoverable only by an app restart - or by the parked worker
/// eventually returning and rolling back cleanly (clearWedgeIfStale),
/// which in the wild it does not. A queue-replacement
/// self-heal was implemented in round 7 and reverted in round 8: the
/// wedge outlives the heal, and each heal+retry cycle re-manufactures
/// the multi-output churn that triggers it (parks went 1 to 4 across 27
/// pairs, hitting the cap-derived ceiling of 4). The latch is
/// load-bearing: after a park, the correct action is to stop touching
/// the device. The E1-E3 hardening descendants (worker-local capture
/// rollback, identity-guarded releases, generation-guarded finish)
/// stand. Prevention shrinks the park window; the watchdog contains
/// the rest.
///
/// The v0.4.0/v0.4.1 crash class (engine converter-chain
/// validation, prod-only, cause not observable from our side) is removed
/// BY CONSTRUCTION: no AVAudioEngine exists anywhere in the app any
/// more - no graph, no nodes, no converters, no validators. The share
/// capture is a raw HAL device IOProc driven by one stored C callback
/// straight into the mix bus (input AudioUnits delivered zeros on macOS
/// 26.2 anyway - see captureIOProc's doc). I5 park surfaces shrink
/// accordingly: IOProc creation, AudioDeviceStart/Stop, and
/// IOProc destruction - all FileLog-bracketed, watchdog intact.
///
/// Prevention layer (round-3 era, now historical): the engine-era hangs
/// #2 and #3 were node-format queries (outputFormat(forBus:),
/// connect(format: nil) resolving the input node's HW format) - both the
/// same GetClientFormat sync through the unit's internal serialization.
/// All wiring formats were pre-built from park-safe device-object HAL
/// reads; today the raw IOProc path has no client formats at all, so
/// that park class is gone entirely. The stale-worker
/// path performs a REAL quiet rollback (capture stop, multi-output
/// destroy, state clear) and clears the wedge latch, so a worker that
/// eventually unparks leaves the sharer usable instead of stuck-restart-only.
///
/// Prevention layer (round-4 era): hang #4 was an apply-class park -
/// connect(format:) applying a client format onto MID-UNSTACK state (the
/// BlackHole still reconfiguring +2s after a teardown; observable symptom:
/// the input-scope ASBD reads 1ch when healthy is 2ch). The historical
/// stack was post-teardown cooldown -> rate-settle wait -> pin ->
/// input-ASBD stability probe -> explicit client formats; today only the
/// cooldown and the probe remain (no pin, no client formats). Containment
/// is unchanged: worker queue + 8s watchdog + stale gates + wedge hygiene.
///
/// Round 5: the park class is confirmed as TIMING - client-format
/// application during unstack; the wired value is irrelevant. The probe
/// therefore requires >= 2ch for acceptance, and a persistent sub-healthy
/// read terminates in a RETRYABLE REFUSAL (code 38, one in-band 2s
/// auto-retry), never in a connect. The watchdog is epoch-guarded so each
/// re-arm (including the code-38 retry's) gets a fresh budget instead of a
/// pending stale timer false-wedging the longer legitimate path.
///
/// Round 9 (prod crash fix): the last manufactured reconfiguration is
/// gone - the sharer no longer calls setNominalSampleRate (the rate set's
/// trailing realloc was the round-9 crash class). Capture follows the
/// device's NATIVE rate: the input-ASBD probe is the SOLE rate authority,
/// the mix bus arms after capture start with the probed capture rate, and
/// a ratio guard (captureRate/renderRate within [0.75, 1.5], code 39)
/// bounds the servo's linear-SRC operating range instead of aliasing on
/// an exotic leftover rate.

/// Real-time state for the share capture IOProc. Plain final class: the
/// IOProc is a bare C function with NO ObjC entry, so the context
/// must not be touchable as an ObjC object (a Swift class with any
/// @objc-visible member gets a runtime header the callback path must
/// never traverse; a plain final class without @objc exposure has none
/// that the HAL touches). RT rules: the IOProc takes NO locks, does NO
/// allocation, and touches NO ObjC runtime - it copies the device bytes
/// into the preallocated data area and pushes raw pointers into the mix
/// bus's lock-free ring; that is all. The context is handed to the
/// IOProc as a refCon via Unmanaged.passUnretained: the sharer owns the
/// context for the IOProc's whole lifetime and destroys the IOProc
/// before dropping the context, so the callback can never observe a
/// dead refCon.
fileprivate final class CaptureContext {
    /// Channel count of the probed capture format.
    let channels: Int
    let mixBus: SystemMixBus

    /// Preallocated capture list, shaped to the PROBED device format:
    /// BlackHole delivers INTERLEAVED (verified on-device: one buffer,
    /// all channels packed), so the shape is a single buffer of
    /// `channels` x 4096 frames x Float32. Built ONCE at build time;
    /// the IOProc only fills it. Non-interleaved capture is rejected in
    /// startCaptureUnit before this init runs.
    let bufferListPtr: UnsafeMutableRawPointer
    let capacityFrames: UInt32 = 4096
    let interleaved: Bool
    /// Byte capacity of the FIRST buffer's data area (frames x channels
    /// x 4), stored at init. The raw IOProc clamps its copy against
    /// THIS - clamping against a whole-list capacity would overrun
    /// buffer 0's storage on any multi-buffer layout.
    let buffer0Bytes: Int
    /// The capture list's DATA area (first buffer's mData) - the raw
    /// IOProc copies device bytes here, leaving the list header intact
    /// for the callback's layout-aware walk.
    var dataPtr: UnsafeMutableRawPointer {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>(OpaquePointer(bufferListPtr))
        )
        return abl[0].mData!
    }

    /// Scratch deinterleave targets for the interleaved path (ch0/ch1
    /// strided out before the mix-bus push). Preallocated: RT no-alloc.
    let scratchL: UnsafeMutablePointer<Float>
    let scratchR: UnsafeMutablePointer<Float>

    /// Count of IOProc invocations where the device delivered more bytes
    /// than buffer0Bytes (the copy was clamped). Written by the RT
    /// IOProc, read and logged only in stopCaptureUnit AFTER the device
    /// is stopped (no concurrent writer remains).
    nonisolated(unsafe) var overflowCount: Int = 0

    init(channels: Int, interleaved: Bool, mixBus: SystemMixBus) {
        precondition(interleaved,
                     "non-interleaved capture is unsupported; startCaptureUnit rejects it")
        self.channels = channels
        self.interleaved = interleaved
        self.mixBus = mixBus
        self.scratchL = .allocate(capacity: 4096)
        self.scratchR = .allocate(capacity: 4096)
        let listSize = MemoryLayout<AudioBufferList>.size
        let dataSize = 4096 * channels * MemoryLayout<Float>.size
        buffer0Bytes = dataSize
        let total = listSize + dataSize
        bufferListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: total, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        memset(bufferListPtr, 0, total)
        let buffers = UnsafeMutableAudioBufferListPointer(
            bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
        )
        buffers.count = 1
        buffers[0] = AudioBuffer(
            mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(dataSize),
            mData: bufferListPtr + listSize
        )
    }

    deinit {
        bufferListPtr.deallocate()
        scratchL.deallocate()
        scratchR.deallocate()
    }
}

/// Opaque handle for a live share capture: the raw HAL IOProc and its
/// device.
fileprivate struct ShareCaptureHandle {
    /// Identity tag (IOProc IDs are function-pointer typealiases on
    /// this SDK and not comparable; a monotonically increasing tag
    /// serves the ownership comparison).
    private static var nextTag: UInt32 = 0
    let tag: UInt32
    let device: AudioDeviceID
    let ioProc: AudioDeviceIOProcID

    init(device: AudioDeviceID, ioProc: AudioDeviceIOProcID) {
        ShareCaptureHandle.nextTag += 1
        self.tag = ShareCaptureHandle.nextTag
        self.device = device
        self.ioProc = ioProc
    }
}

/// The share capture IOProc: a STORED C function pointer, NOT a
/// closure (no context capture means no ObjC, no allocation, no
/// locking on the RT thread). The raw HAL device IOProc receives the
/// BlackHole's input buffer list DIRECTLY (input AudioUnits deliver
/// zeros on macOS 26.2 - see the mic path's micIOProc note); the bytes
/// are copied into the context's preallocated data area, strided into
/// ch0/ch1, and pushed into the mix bus's lock-free ring.
fileprivate let captureIOProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, clientData -> OSStatus in
    guard let clientData else { return noErr }
    let context = Unmanaged<CaptureContext>.fromOpaque(clientData).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inInputData)
    )
    guard abl.count > 0, let data = abl[0].mData else { return noErr }
    let deviceBytes = Int(abl[0].mDataByteSize)
    let byteCount = min(deviceBytes, context.buffer0Bytes)
    if deviceBytes > context.buffer0Bytes {
        context.overflowCount += 1
    }
    if byteCount > 0 {
        context.dataPtr.copyMemory(from: data, byteCount: byteCount)
    }
    let frames = byteCount / 4 / max(1, context.channels)
    guard frames > 0 else { return noErr }
    let frameCount = min(frames, Int(context.capacityFrames))
    // BlackHole's native shape: one buffer, channels interleaved
    // (verified on-device; non-interleaved is rejected at start).
    // Stride ch0/ch1 out into the preallocated scratch pair (RT:
    // no allocation), then push. Mono devices push ch0 directly.
    let samples = context.dataPtr.assumingMemoryBound(to: Float.self)
    let stride = context.channels
    if stride >= 2 {
        let l = context.scratchL
        let r = context.scratchR
        var i = 0
        while i < frameCount {
            l[i] = samples[i * stride]
            r[i] = samples[i * stride + 1]
            i += 1
        }
        context.mixBus.pushStereo(ch0: l, ch1: r, count: frameCount)
    } else {
        context.mixBus.push(samples: samples, count: frameCount)
    }
    return noErr
}

@Observable
final class SystemAudioSharer {

    static let multiOutputUID = AudioDeviceManager.shareMultiOutputUID
    private static let previousOutputKey = "systemAudioPreviousOutputUID"

    /// Worker queue for every HAL mutation (invariant I5). Main
    /// never dispatches sync onto this queue, so main.sync hops from the
    /// queue back to main are deadlock-free.
    private let shareQueue = DispatchQueue(label: "dev.zackslash.Szept.share",
                                           qos: .userInitiated)

    private(set) var isSharing = false
    /// True while an enable/disable transition is queued or running (and
    /// while a parked worker is wedged). UI double-dispatch guard.
    private(set) var isBusy = false
    var mixBus = SystemMixBus()

    /// Set by the watchdog when a transition worker parks past the 8s
    /// deadline. All transitions refuse to start while set; only an app
    /// restart clears it (the wedged worker cannot be unwound safely).
    private(set) var shareQueueWedged = false
    /// Last-recovery message for the user (watchdog parking, etc.). The
    /// next UI toggle surfaces it via lastError.
    private(set) var userNotice: String?

    /// Clears a surfaced notice once the caller has displayed it.
    func clearUserNotice() {
        userNotice = nil
    }

    /// True between the start and end of a teardown, so a re-entrant
    /// enable() or disable() cannot interleave with one in progress.
    private var isTearingDown = false

    /// Bumped at every transition start (and by the watchdog), so a stale
    /// worker that eventually unparks cannot publish anything: every
    /// published flip from the queue is guarded by generation equality.
    private var transitionGeneration = 0

    /// When the last performTeardown returned. Enables sleep out a cooldown
    /// from this stamp: every observed park (hangs #3, #4) was an audio
    /// touch 2-5s after teardown unstack churn. Queue-confined.
    private var lastTeardownCompletedAt: Date?
    private static let postTeardownCooldown: TimeInterval = 3.0

    /// Probe cap for the input-ASBD stability wait (round-5 evidence: the
    /// unstack outlasted the 3s cooldown's ~2s effective remainder plus the
    /// old 1.5s cap, so the cap now terminates in REFUSAL - code 38, one
    /// in-band auto-retry - which makes a longer cap safe). Cadence is
    /// unchanged at 100ms.
    private static let formatProbeCap: TimeInterval = 4.0

    /// Bumped on every armWatchdog call, main-confined alongside
    /// transitionGeneration: a newer arm supersedes (invalidates) every
    /// earlier pending watchdog timer.
    private var watchdogEpoch = 0

    /// The live capture + its RT context. Queue-confined state:
    /// written by performEnable on shareQueue after a successful start,
    /// read and cleared by performDisable/performTeardown on the SAME
    /// serial queue - no hops, no races. (Round 10: replaces the
    /// main-published currentEngine; a capture handle is a value type
    /// with an identity tag, so there is nothing to dealloc-transfer.)
    private var activeUnit: ShareCaptureHandle?
    private var activeContext: CaptureContext?

    private(set) var multiOutputID: AudioDeviceID?
    /// The multi-output's BlackHole member, exposed so a mic rebuild can
    /// detect a member collision (the same BlackHole in both the private
    /// aggregate and the multi-output is the forbidden configuration).
    private(set) var memberDeviceID: AudioDeviceID?
    /// The render rate the mix bus servo was armed with (set in enable()).
    /// A rate-changing mic rebuild must re-enable the share instead of
    /// leaving the servo at a stale nominal ratio.
    private(set) var armedRenderRate: Double?

    /// Weak back-reference to the mic processor, set from enable()'s
    /// parameter. Needed by teardown to stop the mic pipeline in the safe
    /// order (before the multi-output is destroyed).
    private weak var micProcessor: MicProcessor?

    /// Injected by AppState: restarts the mic pipeline after a teardown
    /// that stopped it (cycleMic). Invoked on the main thread.
    var restartMicAfterShareTeardown: (() -> Void)?

    // MARK: - Enable

    /// Ordered enable with full rollback on any failure. Main-thread entry:
    /// validates state, publishes isBusy, arms the watchdog (entry-side:
    /// the queue body must never run unwatched), and dispatches the real
    /// work to shareQueue (invariant I5); the worker re-arms after its
    /// bounded cooldown to supervise real work. The capture IOProc is
    /// created and started BEFORE the multi-output exists, on the
    /// STANDALONE BlackHole device, so the IOProc never has a reference to
    /// a device being created/destroyed under it (round-9 order):
    /// 1. resolve BlackHole 16ch (required); NO rate set - capture follows
    ///    the device's native rate
    /// 2. save the current default output UID (stale-share cleanup first)
    /// 3. create + start the capture IOProc on the standalone BlackHole
    /// 4. arm the mix bus, using the probe's capture rate (after capture
    ///    start; safe because pushes no-op into an unarmed bus = silence)
    /// 5. create the multi-output (speakers main, BlackHole member)
    /// 6. flip the default output to the multi-output
    /// 7. isSharing = true (last)
    @MainActor
    func enable(micProcessor: MicProcessor) async throws {
        guard !isSharing else { return }
        if shareQueueWedged {
            FileLog.log("share: enable refused, share queue wedged (app restart required)")
            throw NSError(domain: "Szept", code: 37,
                          userInfo: [NSLocalizedDescriptionKey: "Sharing is stuck. Restart the app."])
        }
        if isTearingDown {
            throw NSError(domain: "Szept", code: 35,
                          userInfo: [NSLocalizedDescriptionKey: "Sharing is shutting down, try again."])
        }
        guard !isBusy else {
            FileLog.log("share: enable ignored, transition already in progress")
            return
        }

        isBusy = true
        transitionGeneration &+= 1
        let gen = transitionGeneration
        // Entry-side arm (see armWatchdog): the queue body must never run
        // unwatched (an unwatched exit-path dealloc park), the worker never
        // runs and never arms - isBusy forever with no latch. The epoch
        // bump here supersedes nothing yet; the worker's post-cooldown
        // re-arm (kept below) supervises real work with a fresh budget.
        armWatchdog(gen)
        shareQueue.async { self.performEnable(gen, micProcessor) }
    }

    /// Sequenced disable+enable for AppState's rate-mismatch and
    /// member-collision rebuilds. The naive pair (await disable, then try
    /// await enable) is broken: disable returns at the shareQueue dispatch
    /// while isBusy is still true, so the enable is silently dropped by
    /// the busy guard and the mic is left stopped. This runs BOTH halves
    /// inside ONE isBusy window on the queue: teardown (restartMic: true,
    /// so the mic cycles for the I1 destroy and comes back up) followed
    /// immediately by a fresh enable under a NEW generation with its own
    /// watchdog budget. Errors surface at the end, through the same
    /// userNotice path as enable.
    @MainActor
    func reenable(micProcessor: MicProcessor) async throws {
        if shareQueueWedged {
            FileLog.log("share: re-enable refused, share queue wedged (app restart required)")
            throw NSError(domain: "Szept", code: 37,
                          userInfo: [NSLocalizedDescriptionKey: "Sharing stopped after a snag and needs an app restart. Everything else keeps working."])
        }
        if isTearingDown {
            throw NSError(domain: "Szept", code: 35,
                          userInfo: [NSLocalizedDescriptionKey: "Sharing is shutting down, try again."])
        }
        guard !isBusy else {
            FileLog.log("share: re-enable ignored, transition already in progress")
            return
        }
        guard isSharing else { return }

        // Published first: the render path stops consulting the share
        // before anything is torn down (mirrors disable).
        isSharing = false
        isBusy = true
        isTearingDown = true
        transitionGeneration &+= 1
        let gen = transitionGeneration
        // Entry-side arm (see enable): the queue body must never run
        // unwatched. The post-cooldown re-arm below supersedes this.
        armWatchdog(gen)

        // Snapshot the session state synchronously on main (plain values,
        // no reference semantics to transfer).
        let multiOutputID = multiOutputID
        let memberDeviceID = memberDeviceID
        mixBus.disarm()
        FileLog.log("share: re-enable sequence")

        shareQueue.async { self.performReenable(
            gen: gen, micProcessor: micProcessor,
            multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        ) }
    }

    /// The enable body. Runs on shareQueue (invariant I5): every HAL
    /// mutation happens here, never on main. All published state flips
    /// hop to main, guarded by the transition generation; a stale
    /// generation means the watchdog already gave up on us, so we roll
    /// back quietly and flip nothing.
    private func performEnable(_ gen: Int, _ micProcessor: MicProcessor) {
        var step = "cooldown"
        var multiOutputID: AudioDeviceID?
        var memberDeviceID: AudioDeviceID?
        var defaultFlipped = false
        // The worker's own capture unit + context. startCaptureUnit
        // returns a started unit or throws, so every stale gate below sees
        // it non-nil (bound non-optionally after the retry block).
        var unit: ShareCaptureHandle?
        var context: CaptureContext?

        // Cooldown sleep per lastTeardownCompletedAt's doc (the canonical
        // rationale); the sleep is invisible to main, isBusy already
        // holds the UI.
        step = "cooldown"
        if let stamp = lastTeardownCompletedAt {
            let elapsed = Date().timeIntervalSince(stamp)
            let cooldown = Self.postTeardownCooldown
            if elapsed < cooldown {
                let waitMs = Int((cooldown - elapsed) * 1000)
                FileLog.log("share: [cooldown] waiting \(waitMs)ms post-teardown (HAL settling)")
                usleep(useconds_t(waitMs * 1000))
            }
        }

        // Re-arm AFTER the cooldown: the entry-side arm covers the
        // unwatched window; this one supervises real work only.
        armWatchdog(gen)

        do {
            step = "resolve BlackHole"
            // 1. Prefer BlackHole 16ch by name; fall back to any other
            // BlackHole that is not the mic pipeline's own output device and
            // exposes at least 2 input channels.
            let allDevices = (try? AudioDeviceManager.allDevices()) ?? []
            let blackHoles = allDevices.filter { $0.name.localizedCaseInsensitiveContains("BlackHole") }
            var bh16 = blackHoles.first {
                $0.name.localizedCaseInsensitiveContains("BlackHole")
                    && $0.name.localizedCaseInsensitiveContains("16")
                    // Shared-member invariant: never pick the device the mic
                    // pipeline already feeds; the same BlackHole must never sit
                    // in both the private aggregate and the multi-output.
                    && $0.id != micProcessor.outputDeviceID
            }
            if bh16 == nil {
                bh16 = blackHoles.first {
                    $0.id != micProcessor.outputDeviceID
                        && AudioDeviceManager.inputChannelCount(deviceID: $0.id) >= 2
                }
            }
            guard let blackHole = bh16 else {
                // A 16ch that exists but is excluded is a different problem from
                // one that is missing: the fix is a second device, not an install.
                let excluded16 = blackHoles.contains {
                    $0.name.localizedCaseInsensitiveContains("BlackHole")
                        && $0.name.localizedCaseInsensitiveContains("16")
                }
                throw NSError(domain: "Szept", code: 30,
                              userInfo: [NSLocalizedDescriptionKey: excluded16
                                  ? "BlackHole 16ch is in use as the Szept output device. Install a second BlackHole (2ch or 16ch) for system-audio sharing."
                                  : "BlackHole 16ch not installed (brew install --cask blackhole-16ch)"])
            }
            // Round 9: NO rate set. The setNominalSampleRate + settle loop
            // is gone - it was the last manufactured reconfiguration (the
            // round-9 prod crash class: rate-set trailing realloc). Capture
            // follows the device's native rate instead; the probe in
            // startCaptureUnit is the sole rate authority.
            let deviceRate = AudioDeviceManager.nominalSampleRate(deviceID: blackHole.id) ?? 48000
            FileLog.log("share: [resolve BlackHole] capturing at device rate \(Int(deviceRate)) Hz (no rate set)")

            step = "save previous output"
            // 2. Persist the current default output. If the current default
            // IS a stale share device, run stale cleanup first so we never
            // save our own device as the thing to restore. A loopback
            // (BlackHole) default would mean restoring INTO a loopback and
            // hearing nothing, so refuse before persisting anything.
            if AudioDeviceManager.defaultOutputDeviceUID() == Self.multiOutputUID {
                FileLog.log("share: [save previous output] stale-share restore (park-capable)")
                Self.restorePreviousOutputFromDefaults()
                FileLog.log("share: [save previous output] stale-share restore done")
            }
            if let current = AudioDeviceManager.defaultOutputDeviceUID() {
                if current.localizedCaseInsensitiveContains("BlackHole") {
                    throw NSError(domain: "Szept", code: 32,
                                  userInfo: [NSLocalizedDescriptionKey: "System default output is a loopback device. Set your real speakers as the default output, then share."])
                }
                guard current != Self.multiOutputUID else {
                    throw NSError(domain: "Szept", code: 34,
                                  userInfo: [NSLocalizedDescriptionKey: "Share was left as the system default and the previous output is gone. Pick a default output in System Settings, then share again."])
                }
                UserDefaults.standard.set(current, forKey: Self.previousOutputKey)
            }

            step = "start capture unit"
            // 3. Build + start the capture unit pinned to the STANDALONE
            // BlackHole, before the multi-output exists. One retry after a
            // 250 ms settle for residual races. The retry catches
            // HAL-REFUSED THROWS only: a park does not throw, it just never
            // returns; the watchdog owns those.
            self.micProcessor = micProcessor
            var captureRate: Double = 48000
            do {
                (unit, context, captureRate) = try startCaptureUnit(blackHoleID: blackHole.id)
            } catch {
                if (error as NSError).code == 38 {
                    // Probe refusal: one in-band 2s auto-retry; see
                    // formatProbeCap's coupling invariant (this legitimate
                    // path runs ~10s total, so the re-arm supersedes the
                    // first watchdog).
                    FileLog.log("share: device still settling, retrying once in 2s")
                    armWatchdog(gen)
                    usleep(2_000_000)
                } else {
                    FileLog.log("share: [\(step)] capture unit start failed (\(error.localizedDescription)), retrying once after 250ms")
                    armWatchdog(gen)
                    discardPartialUnit(unit: unit, context: context, label: step)
                    unit = nil
                    context = nil
                    usleep(250_000)
                }
                (unit, context, captureRate) = try startCaptureUnit(blackHoleID: blackHole.id)
            }
            // From here the worker owns a live capture; bind the locals
            // non-optionally for the gates and the rollback path.
            guard let unit, let context else {
                throw NSError(domain: "Szept", code: 33,
                              userInfo: [NSLocalizedDescriptionKey: "Capture unit did not start"])
            }
            // Queue-confined state handoff: disable's teardown runs on this
            // same serial queue, so it will observe these writes.
            self.activeUnit = unit
            self.activeContext = context

            step = "arm mix bus"
            // 4. Arm the mix bus AFTER the unit start (round 9 reorder):
            // single rate authority - captureRate comes from the probe's
            // ASBD (the stream the callback actually delivers), not from a
            // separate nominalSampleRate read (the latent disagreement this
            // kills). Arming this late is safe: the callback's push no-ops
            // while the ring is nil (guard let ring), drainRing cannot mix
            // before the active flag flips; the few ms of capture that
            // landed in a not-yet-armed bus are silence. The ratio guard
            // bounds the linear-SRC servo's operating range instead of
            // aliasing on an exotic leftover rate.
            let renderRate = micProcessor.renderSampleRate ?? 48000
            let ratio = captureRate / renderRate
            if !(0.75...1.5).contains(ratio) {
                throw NSError(domain: "Szept", code: 39,
                              userInfo: [NSLocalizedDescriptionKey: "BlackHole is set to \(Int(captureRate)) Hz while your mic runs at \(Int(renderRate)) Hz. Set BlackHole's rate to match in Audio MIDI Setup, then share."])
            }
            let armedRate = renderRate
            publishIfCurrent(gen) { self.armedRenderRate = armedRate }
            mixBus.arm(inputRate: captureRate, outputRate: renderRate)

            // STALE GATE 1: the watchdog may have abandoned this worker
            // while the unit start parked. Before creating anything new,
            // roll back quietly with the local state. defaultFlipped is
            // constant false here (and at gate 2): both gates precede the
            // irreversible flip; gate 3, after it, passes true.
            if isStale(gen) { return rollbackStaleWorker(gen: gen, step: step, defaultFlipped: false, unit: unit, context: context, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID) }

            step = "create multi-output"
            // 5. Multi-output: previous default (the speakers) as clock
            // master and app-facing format, BlackHole as drift-compensated
            // member.
            guard let mainUID = AudioDeviceManager.defaultOutputDeviceUID() else {
                throw NSError(domain: "Szept", code: 31,
                              userInfo: [NSLocalizedDescriptionKey: "Could not read the current output device"])
            }
            memberDeviceID = blackHole.id
            FileLog.log("share: [create multi-output] creating (park-capable)")
            let createdID = try AudioDeviceManager.createMultiOutputDevice(
                mainUID: mainUID, memberUID: blackHole.uid
            )
            FileLog.log("share: [create multi-output] created id \(createdID)")
            multiOutputID = createdID
            let capturedMember = memberDeviceID
            publishIfCurrent(gen) {
                self.multiOutputID = createdID
                self.memberDeviceID = capturedMember
            }

            // STALE GATE 2: the default flip is the irreversible step - a
            // worker the watchdog already abandoned must never perform it.
            if isStale(gen) { return rollbackStaleWorker(gen: gen, step: step, defaultFlipped: false, unit: unit, context: context, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID) }

            step = "flip default output"
            // 6. Flip the default output to the multi-output. The mic path
            // has no engine and every IOProc and unit targets its own
            // device (I6), so this flip is structurally invisible to the
            // rest of the pipeline.
            FileLog.log("share: [flip default output] flipping (park-capable)")
            try AudioDeviceManager.setDefaultOutputDevice(id: createdID)
            defaultFlipped = true
            FileLog.log("share: [flip default output] flipped to multi-output")
            // STALE GATE 3: the flip is park-capable and sits 4-13s
            // post-teardown where the unstack churn lives. Without this
            // gate, a flip that parks across the watchdog orphans a live
            // session: isSharing=false wedged while the device stack stays
            // up, so disable/enable/quit all refuse and drainRing keeps
            // mixing on bus.isActive.
            if isStale(gen) { return rollbackStaleWorker(gen: gen, step: step, defaultFlipped: true, unit: unit, context: context, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID) }

            // 7. Published last: the UI and the render path only see the
            // share once unit, device flip, and mix bus are all live.
            publishIfCurrent(gen) { self.isSharing = true }
            FileLog.log("share: [done] system audio sharing enabled")
        } catch {
            let ns = error as NSError
            FileLog.log("share: enable FAILED at step \(step): \(ns.domain) code \(ns.code) - \(ns.localizedDescription)")
            mixBus.disarm()
            // cycleMic=false when the default flip never succeeded: the mic
            // pipeline never referenced the multi-output, so it must NOT be
            // stopped. If the flip happened, stop the mic and restart it.
            performTeardown(
                gen: gen, reason: "enable rollback",
                restartMic: true, cycleMic: defaultFlipped,
                unit: unit, context: context,
                multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
            )
            // Surface the failure to the user on main.
            DispatchQueue.main.async {
                if gen == self.transitionGeneration {
                    self.userNotice = ns.localizedDescription
                }
            }
        }
        // A capture handle is a value type: dropping the
        // worker frame's copy deallocates NOTHING. There is no dealloc
        // park class here; disposal is explicit and bracketed in
        // performTeardown above.
        finishTransition(gen: gen)
    }

    /// Sequenced re-enable body (see reenable). Runs on shareQueue:
    /// disable-equivalent teardown, then a fresh enable under a NEW
    /// generation with its own watchdog budget, all inside the ONE isBusy
    /// window the entry opened.
    private func performReenable(gen: Int, micProcessor: MicProcessor,
                                 multiOutputID: AudioDeviceID?,
                                 memberDeviceID: AudioDeviceID?) {
        performTeardown(
            gen: gen, reason: "re-enable",
            restartMic: true, cycleMic: true,
            unit: activeUnit, context: activeContext,
            multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        )
        if isStale(gen) { clearWedgeIfStale(gen) }
        // Fresh generation for the enable half: the teardown above
        // finished under the old one.
        let enableGen = DispatchQueue.main.sync {
            self.transitionGeneration &+= 1
            return self.transitionGeneration
        }
        performEnable(enableGen, micProcessor)
        FileLog.log("share: re-enable sequence done")
    }

    /// Quiet rollback for a stale (watchdog-abandoned) enable worker that
    /// eventually returned: tear down with the LOCAL state, clear the
    /// wedge latch (shareQueueWedged, via clearWedgeIfStale), clear the
    /// transition flags, and flip nothing. Runs on shareQueue; called by
    /// the stale gates (returns from performEnable). Takes the worker's
    /// OWN unit and context: under the latch protocol no newer session can
    /// exist while wedged (enable refuses), but a teardown must only
    /// release what it owns - this worker's frame references are exactly
    /// that, and the queue-confined activeUnit/activeContext are cleared
    /// inside performTeardown when they match.
    private func rollbackStaleWorker(gen: Int, step: String, defaultFlipped: Bool,
                                     unit: ShareCaptureHandle,
                                     context: CaptureContext,
                                     multiOutputID: AudioDeviceID?,
                                     memberDeviceID: AudioDeviceID?) {
        FileLog.log("share: stale worker returned (gen \(gen)); rolling back quietly (step was: \(step))")
        performTeardown(
            gen: gen, reason: "stale rollback",
            restartMic: true, cycleMic: defaultFlipped,
            unit: unit, context: context,
            multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        )
        clearWedgeIfStale(gen)
        finishTransition(gen: gen)
    }

    /// Capture-format cache codec: "rate,channels,interleaved(0|1)".
    /// Three fields; older 4-field entries (a formatFlags rode along)
    /// fail the parts.count check and self-heal to a fresh probe.
    /// The cache exists because in-process stream-format reads poison
    /// after the first capture teardown (see startCaptureUnit).
    private func captureFormatString(rate: Double, channels: Int, interleaved: Bool) -> String {
        "\(Int(rate)),\(channels),\(interleaved ? 1 : 0)"
    }

    private func parseCaptureFormat(_ s: String) -> (Double, Int, Bool)? {
        let parts = s.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3,
              (8_000...192_000).contains(parts[0]),
              (2...64).contains(parts[1]) else { return nil }
        return (Double(parts[0]), parts[1], parts[2] == 1)
    }

    /// Park-safety gate for the capture start: wait until the device's
    /// input ASBD is sane, stable, AND >= 2ch before the IOProc is
    /// created (park class of hang #4; see the class doc's round-4/5
    /// notes). Reads go through AudioDeviceManager.inputStreamFormat
    /// (device-object, park-safe). The first sane >=2ch read is trusted
    /// outright (probe-on-suspicion); otherwise re-read every 100ms up to
    /// formatProbeCap (4.0s), accepting two consecutive identical sane
    /// reads with the accepted read >= 2ch. At cap expiry: log and THROW
    /// code 38 (the caller performs one in-band 2s auto-retry). Never
    /// returns nil: read failures run to the cap and throw 38 exactly
    /// like sub-healthy reads - a device we cannot read sanely is a
    /// device we must not capture from.

    private func probeStableInputFormat(deviceID: AudioDeviceID) throws -> (asbd: AudioStreamBasicDescription, source: String) {
        func read() -> AudioStreamBasicDescription? {
            AudioDeviceManager.inputStreamFormat(deviceID: deviceID)
        }
        // Fast path: healthy devices answer sane 2ch on the first read.
        if let first = read(), first.mChannelsPerFrame >= 2 {
            return (first, "device ASBD")
        }

        var previous: AudioStreamBasicDescription?
        var waitedMs = 0
        let cap = Int(Self.formatProbeCap * 1000)
        while waitedMs < cap {
            usleep(100_000)
            waitedMs += 100
            guard let current = read() else { previous = nil; continue }
            if let prev = previous, prev.mSampleRate == current.mSampleRate,
               prev.mChannelsPerFrame == current.mChannelsPerFrame,
               current.mChannelsPerFrame >= 2 {
                // Two consecutive identical sane >=2ch reads: stable.
                FileLog.log("share: [fmt] probe waited \(waitedMs)ms, stabilized \(Int(current.mSampleRate)) Hz \(current.mChannelsPerFrame) ch")
                return (current, "device ASBD (stabilized)")
            }
            previous = current
        }
        let last = previous
        FileLog.log("share: [fmt] probe cap reached (last \(last.map { "\(Int($0.mSampleRate)) Hz \($0.mChannelsPerFrame) ch" } ?? "no sane read")) - refusing")
        throw NSError(domain: "Szept", code: 38,
                      userInfo: [NSLocalizedDescriptionKey: "BlackHole is still settling after share teardown. Try again in a few seconds."])
    }

    /// Create, wire, and start the share capture: a raw HAL device
    /// IOProc on the BlackHole with one stored C callback feeding the
    /// mix bus. No AudioUnit, no graph, no converters - the
    /// v0.4.0/v0.4.1 crash class (engine converter-chain validation) is
    /// removed by construction (input AudioUnits deliver zeros on macOS
    /// 26.2 anyway; see captureIOProc's doc). Runs on shareQueue. Every
    /// park-capable call is FileLog-bracketed so a post-mortem shows
    /// exactly which call parked. Returns the capture handle, its RT
    /// context, and the probe's ASBD rate (the SOLE rate authority: the
    /// stream the IOProc actually delivers).
    private func startCaptureUnit(blackHoleID: AudioDeviceID) throws -> (capture: ShareCaptureHandle, context: CaptureContext, captureRate: Double) {
        // (0) Rate/channel authority. FIRST enable in a fresh process:
        // probe the device object (sane, stable read). Every LATER enable:
        // use the persisted cache, VALIDATED against the live device:
        // nominalSampleRate and the input channel count are plain
        // device-object reads that never poison, so a cache that
        // disagrees with the live device (user changed BlackHole's rate
        // or swapped models) is dropped and re-probed in the same run.
        // The cache exists because after the first capture teardown the
        // process's OWN stream-format reads of the pinned device return
        // a phantom 1ch FOREVER (10+ min observed) while every other
        // process reads a healthy 16 ch on both scopes - a per-process
        // HAL cache our own client history poisons. NOTE: no in-band
        // self-heal exists anymore (the -50 shape-mismatch heal died
        // with the render path); the cache validation above and the mix
        // bus's ratio guard (code 39) are what cover format drift.
        let cacheKey = "shareCaptureFormatCache"
        var rate: Double = 0
        var channels = 0
        var interleaved = true
        var source = ""
        var cacheHit = false
        if let cached = UserDefaults.standard.string(forKey: cacheKey),
           let parsed = parseCaptureFormat(cached) {
            let (cachedRate, cachedChannels, cachedInterleaved) = parsed
            let liveRate = AudioDeviceManager.nominalSampleRate(deviceID: blackHoleID) ?? 0
            let liveChannels = AudioDeviceManager.inputChannelCount(deviceID: blackHoleID)
            if liveRate > 0, liveRate == cachedRate, liveChannels == cachedChannels {
                rate = cachedRate
                channels = cachedChannels
                interleaved = cachedInterleaved
                source = "cached"
                cacheHit = true
                FileLog.log("share: [fmt] capture format \(Int(rate)) Hz, \(channels) ch \(interleaved ? "interleaved" : "non-interleaved") (\(source)) - probe skipped (in-process reads poison after first teardown)")
            } else {
                UserDefaults.standard.removeObject(forKey: cacheKey)
                FileLog.log("share: [fmt] cache stale (live \(Int(liveRate)) Hz \(liveChannels) ch vs cached \(Int(cachedRate)) Hz \(cachedChannels) ch), re-probing")
            }
        }
        if !cacheHit {
            let probed = try probeStableInputFormat(deviceID: blackHoleID)
            rate = probed.asbd.mSampleRate
            channels = Int(probed.asbd.mChannelsPerFrame)
            interleaved = probed.asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            source = probed.source
            UserDefaults.standard.set(captureFormatString(rate: rate, channels: channels, interleaved: interleaved), forKey: cacheKey)
            FileLog.log("share: [fmt] capture format \(Int(rate)) Hz, \(channels) ch \(interleaved ? "interleaved" : "non-interleaved") (\(source)) - device-native")
        }
        // Non-interleaved capture is unsupported: the IOProc's byte-copy
        // and stride walk assume one packed buffer. Every BlackHole is
        // verified interleaved, so this is a fatal-but-surfaced refusal,
        // not a silent wrong-signal path.
        guard interleaved else {
            FileLog.log("share: [fmt] FATAL: capture device reports a non-interleaved input stream; the capture path only supports interleaved")
            throw NSError(domain: "Szept", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "The capture device reports an unsupported (non-interleaved) input format. Sharing cannot start."])
        }

        // (1) Create the raw HAL input IOProc on the BlackHole (no
        // AudioUnit: input AudioUnits deliver zeros on macOS 26.2 -
        // see captureIOProc's doc and the mic path's micIOProc). The
        // IOProc receives the device's input buffer list directly.
        let context = CaptureContext(channels: channels, interleaved: interleaved, mixBus: mixBus)
        FileLog.log("share: [start capture] creating IOProc (park-capable)")
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(
            blackHoleID, captureIOProc,
            Unmanaged.passUnretained(context).toOpaque(),
            &newProc
        )
        FileLog.log("share: [start capture] IOProc created: \(procStatus)")
        guard procStatus == noErr, let ioProc = newProc else {
            throw AudioDeviceError.queryFailed(procStatus)
        }

        // (2) Start the device IO cycle.
        FileLog.log("share: [start capture] starting device (park-capable)")
        let startStatus = AudioDeviceStart(blackHoleID, ioProc)
        FileLog.log("share: [start capture] device started: \(startStatus)")
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(blackHoleID, ioProc)
            throw AudioDeviceError.queryFailed(startStatus)
        }

        // (3)
        FileLog.log("share: [start capture] live, \(Int(rate)) Hz \(channels) ch")
        return (ShareCaptureHandle(device: blackHoleID, ioProc: ioProc), context, rate)
    }

    // MARK: - Disable

    /// Idempotent teardown. Main-thread entry: publishes isSharing=false
    /// SYNCHRONOUSLY (the sleep path and the UI depend on it), then
    /// dispatches the HAL work to shareQueue (invariant I5).
    /// RESTORE BEFORE DESTROY: the default output is moved back to the
    /// saved device while the multi-output still exists, so the restore can
    /// never dangle on a destroyed device. The mic pipeline is stopped (and
    /// optionally restarted via the injected closure) INSIDE the teardown,
    /// in the safe order.
    @MainActor
    func disable(restartMic: Bool = true) async {
        guard isSharing else { return }
        guard !isBusy, !isTearingDown else {
            FileLog.log("share: disable refused, transition already in progress")
            return
        }

        // Published FIRST so UI and render path stop consulting the share
        // before anything is torn down.
        isSharing = false
        isBusy = true
        isTearingDown = true
        transitionGeneration &+= 1
        let gen = transitionGeneration
        armWatchdog(gen)

        // Snapshot the published session state synchronously on main
        // (plain values; the live unit/context are queue-confined and are
        // read on the queue).
        let multiOutputID = multiOutputID
        let memberDeviceID = memberDeviceID

        // Barrier first: the render thread stops mixing immediately; the
        // ring is intentionally never freed.
        mixBus.disarm()
        FileLog.log("share: system audio sharing disabled")

        shareQueue.async { self.performDisable(
            gen: gen, restartMic: restartMic,
            multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        ) }
    }

    /// The disable body. Runs on shareQueue (invariant I5).
    private func performDisable(gen: Int, restartMic: Bool,
                                multiOutputID: AudioDeviceID?,
                                memberDeviceID: AudioDeviceID?) {
        // Stale gate: disable's steps only UNDO, so a returning stale
        // worker still runs the teardown (restorative), but it must not
        // race a newer session - restartMic is skipped. While wedged, no
        // newer session can exist (enable refuses), so there is nothing to
        // race unless the wedge was already cleared.
        //
        // Asymmetry note (whole-saga evidence): teardown ops ON THE QUEUE
        // never parked - reader-side wind-down (stop/uninit/dispose) plus
        // device-object sets (restore/destroy). The park class is
        // WRITER-side format application (startCaptureUnit only). Revisit
        // if any teardown bracket ever parks.
        let stale = isStale(gen)
        if stale {
            FileLog.log("share: stale worker returned (gen \(gen)); disable teardown runs restoratively, no mic restart")
        }
        performTeardown(
            gen: gen, reason: "disable",
            restartMic: stale ? false : restartMic, cycleMic: true,
            unit: activeUnit, context: activeContext,
            multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        )
        if stale { clearWedgeIfStale(gen) }
        finishTransition(gen: gen)
    }

    // MARK: - Teardown

    /// The capture-side teardown, in the exact order that keeps the
    /// deadlock invariant I1 (see the class comment): historically the
    /// only implicit default-output client was the MIC pipeline, and it
    /// was stopped BEFORE the multi-output was destroyed; today the mic
    /// path has no default-output client (I6), so the mic stop is
    /// belt-and-braces ordering only, and the share capture goes down
    /// first simply as wind-down. Runs on shareQueue. One
    /// FileLog line per step plus park brackets, mirroring the
    /// enable/disable log names.
    /// - cycleMic=false is for the enable-catch, where the default flip
    ///   never succeeded and the mic pipeline never referenced the
    ///   multi-output, so it must not be stopped.
    private func performTeardown(gen: Int, reason: String,
                                 restartMic: Bool, cycleMic: Bool,
                                 unit: ShareCaptureHandle?,
                                 context: CaptureContext?,
                                 multiOutputID: AudioDeviceID?,
                                 memberDeviceID: AudioDeviceID?) {
        // 1. Stop and dispose the share capture unit (explicit, bracketed;
        // a capture handle is a value type - no dealloc
        // transfer story exists).
        stopCaptureUnit(unit: unit, context: context, label: reason)
        if activeUnit?.tag == unit?.tag { activeUnit = nil }
        if activeContext === context { activeContext = nil }

        // 2. Stop the mic pipeline. Historically load-bearing (the old
        // engine was unpinned and an implicit HAL client of whatever the
        // default output was); today the mic path has NO default-output
        // client (I6), so this is belt-and-braces ordering retained for
        // the I1 invariant.
        var micWasStopped = false
        if cycleMic, micProcessor?.isRunning == true {
            FileLog.log("share: [\(reason)] stopping mic units before multi-output destroy (park-capable)")
            micProcessor?.stop()
            micWasStopped = true
            FileLog.log("share: [\(reason)] mic units stopped before multi-output destroy")
        }

        // 3. Restore the default only if we still own it: the user may have
        // switched devices manually mid-share. RESTORE BEFORE DESTROY, so
        // the restore can never dangle on a destroyed device.
        if let id = multiOutputID,
           AudioDeviceManager.defaultOutputDeviceID() == id {
            FileLog.log("share: [\(reason)] restoring default output (park-capable)")
            Self.restorePreviousOutputFromDefaults()
            FileLog.log("share: [\(reason)] default output restored")
        }

        // 4. (Removed: the suppression window. The mic path has no engine
        // and no default-output client, so the restore flip cannot trigger
        // a rebuild - see invariant I6.)

        // 5. Destroy the multi-output (now unreferenced).
        if let id = multiOutputID {
            FileLog.log("share: [\(reason)] destroying multi-output (park-capable)")
            AudioDeviceManager.destroyShareMultiOutput(id: id)
            FileLog.log("share: [\(reason)] multi-output destroyed")
        }

        // 6. Clear session state (main-confined). Normal path:
        // generation-guarded. Stale path: unconditional-but-identity-
        // guarded - under the latch protocol no newer session can exist
        // while wedged (enable refuses), so a returned stale worker must
        // not leave orphaned session fields pointing at the devices it
        // just destroyed.
        if isStale(gen) {
            DispatchQueue.main.sync {
                if self.multiOutputID == multiOutputID { self.multiOutputID = nil }
                if self.memberDeviceID == memberDeviceID { self.memberDeviceID = nil }
                self.armedRenderRate = nil
            }
        } else {
            publishIfCurrent(gen) {
                self.multiOutputID = nil
                self.memberDeviceID = nil
                self.armedRenderRate = nil
            }
        }

        // 7. Restart the mic pipeline if this teardown stopped it (on main),
        // DEFERRED past the churn window (round 9): v0.4.0's working
        // re-enable path made mic cycles much more frequent, and a restart
        // firing immediately at teardown end lands INSIDE the unstack
        // churn window (>3.5s per rounds 4-5), which makes the mic
        // aggregate creation fail and fall back to direct two-clock
        // routing - the drift-blip mechanism. The 1.5s defer puts the
        // aggregate create on a settled HAL; the extra gap rides the
        // existing cycle gap. Sleep/terminate pass restartMic: false and
        // are unaffected.
        if restartMic, micWasStopped {
            FileLog.log("share: mic restart deferred 1.5s (post-churn settle)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.restartMicAfterShareTeardown?()
            }
        }

        // 8. Stamp teardown completion (queue-confined: written and read
        // only on shareQueue, no hops; performEnable's cooldown sleeps on
        // the same queue, so the handoff is naturally ordered).
        lastTeardownCompletedAt = Date()
    }

    /// Stop and discard a half-built unit + context from a failed start
    /// attempt (before the retry). Runs on shareQueue.
    private func discardPartialUnit(unit: ShareCaptureHandle?,
                                    context: CaptureContext?, label: String) {
        guard let unit else { return }
        stopCaptureUnit(unit: unit, context: context, label: label)
        FileLog.log("share: [\(label)] partial capture discarded")
    }

    /// Stop and destroy a share capture IOProc, with park brackets
    /// around every HAL call, then log the callback's health counters
    /// (written by the RT callback, read only here - the device is
    /// already stopped, so no concurrent writer remains). Runs on
    /// shareQueue.
    private func stopCaptureUnit(unit: ShareCaptureHandle?,
                                 context: CaptureContext?, label: String) {
        guard let unit else { return }
        FileLog.log("share: [\(label)] stopping capture device (park-capable)")
        let stopStatus = AudioDeviceStop(unit.device, unit.ioProc)
        FileLog.log("share: [\(label)] capture device stopped: \(stopStatus)")
        FileLog.log("share: [\(label)] destroying IOProc (park-capable)")
        AudioDeviceDestroyIOProcID(unit.device, unit.ioProc)
        FileLog.log("share: [\(label)] IOProc destroyed")
        if let context {
            if context.overflowCount > 0 {
                FileLog.log("share: [\(label)] capture buffer overflowed \(context.overflowCount) times during session")
            }
        }
    }

    /// Clear the transition flags on main, ONLY when this worker's
    /// generation is still current: the watchdog already cleared both
    /// flags when it declared the transition stale, so an unconditional
    /// clear would be redundant for the stale worker - and actively
    /// harmful, unlocking the UI guard mid-flight for a NEW transition
    /// running under a newer generation.
    private func finishTransition(gen: Int) {
        DispatchQueue.main.async {
            guard gen == self.transitionGeneration else { return }
            self.isBusy = false
            self.isTearingDown = false
        }
    }

    /// Publish a state flip on main, only if this transition is still the
    /// current one. A stale generation means the watchdog already gave up
    /// on this worker: flip nothing.
    private func publishIfCurrent(_ gen: Int, _ apply: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.transitionGeneration else { return }
            apply()
        }
    }

    /// True when the watchdog has already abandoned this transition. Safe
    /// main.sync (see shareQueue's doc).
    private func isStale(_ gen: Int) -> Bool {
        DispatchQueue.main.sync { gen != self.transitionGeneration }
    }

    /// Clear the wedge latch if this worker is stale (the watchdog fired on
    /// it) and it managed to return and roll back: the queue demonstrably
    /// still runs, so sharing can be retried without an app restart. Safe
    /// main.sync (see shareQueue's doc).
    private func clearWedgeIfStale(_ gen: Int) {
        DispatchQueue.main.sync {
            guard gen != self.transitionGeneration, self.shareQueueWedged else { return }
            self.shareQueueWedged = false
            FileLog.log("share: parked worker returned and rolled back; wedge cleared")
        }
    }

    /// +8s main-side watchdog for the current transition: if the worker is
    /// still busy when it fires, the worker is parked in a HAL
    /// call and may NEVER return. Declare sharing stuck instead of hanging
    /// the app: clear the busy flags so the UI unlocks, set the wedged
    /// flag so no new transition starts, and bump the generation so the
    /// (possibly eventually-returning) worker's flips are all treated as
    /// stale.
    private func armWatchdog(_ gen: Int) {
        // Re-arming supersedes prior pending watchdogs: without the epoch
        // guard, the code-38 retry's legitimate ~10s path (4s probe cap +
        // 2s settle + second attempt) would false-wedge when the FIRST
        // arm's +8s timer fired mid-retry.
        //
        // Called from BOTH the share queue (performEnable, retry arms) and
        // main (disable's @MainActor entry). dispatch_sync onto a queue the
        // calling thread already owns is an immediate SIGTRAP, so the main
        // hop must be conditional - unconditional main.sync here was the
        // round-5 crash loop (one trap per share-off toggle).
        func arm() {
            watchdogEpoch += 1
            let epoch = watchdogEpoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let self else { return }
                guard epoch == self.watchdogEpoch, self.isBusy,
                      self.isSharing == false,
                      gen == self.transitionGeneration else { return }
                FileLog.log("share: transition timed out; worker parked - sharing marked stuck")
                self.isSharing = false
                self.isBusy = false
                self.isTearingDown = false
                self.shareQueueWedged = true
                self.transitionGeneration &+= 1
                // A wedged enable leaves the bus armed with a dead capture;
                // inert (drainRing checks isActive on the render thread),
                // but disarm keeps it airtight. Documented main-safe.
                self.mixBus.disarm()
                self.userNotice = "System audio sharing hit a snag and stopped. Everything else is unaffected; sharing returns when you restart the app."
            }
        }
        if Thread.isMainThread { arm() } else { DispatchQueue.main.sync { arm() } }
    }

    /// Device-list change: if BlackHole 16ch or the multi-output vanished,
    /// the share cannot continue.
    func handleDeviceListChange() {
        guard isSharing else { return }
        let devices = (try? AudioDeviceManager.allDevices()) ?? []
        let uids = Set(devices.map(\.uid))
        if !uids.contains(Self.multiOutputUID) {
            FileLog.log("share: multi-output device gone, disabling")
            Task { await self.disable(restartMic: true) }
            return
        }
        let blackHoleGone = !devices.contains {
            $0.name.localizedCaseInsensitiveContains("BlackHole")
                && $0.name.localizedCaseInsensitiveContains("16")
        }
        if blackHoleGone && !devices.contains(where: {
            $0.name.localizedCaseInsensitiveContains("BlackHole")
                && AudioDeviceManager.inputChannelCount(deviceID: $0.id) >= 2
        }) {
            FileLog.log("share: BlackHole device gone, disabling")
            Task { await self.disable(restartMic: true) }
        }
    }

    // MARK: - Launch-time stale cleanup

    /// Called once from applicationDidFinishLaunching BEFORE the lifecycle
    /// observer is created and any audio pipeline starts. Finds share multi-output
    /// leftovers from a crashed session; if one is still the default
    /// output, restore the saved previous device (if resolvable), then
    /// destroy every match. Sanctioned I5 exception: this is the one
    /// main-thread HAL mutation, allowed because it runs pre-pipeline and
    /// pre-observer (see the class doc).
    static func cleanupStaleDevices() {
        if AudioDeviceManager.defaultOutputDeviceUID() == multiOutputUID {
            restorePreviousOutputFromDefaults()
        }
        AudioDeviceManager.findAndDestroyStaleShareMultiOutput()
    }

    /// Restore the default output from the saved UID when it resolves.
    /// If it does not resolve, leave things alone: destroying the
    /// multi-output makes the system fall back on its own.
    private static func restorePreviousOutputFromDefaults() {
        guard let uid = UserDefaults.standard.string(forKey: previousOutputKey),
              let device = try? AudioDeviceManager.findDevice(uid: uid) else {
            FileLog.log("share: saved previous output not resolvable, leaving default as-is")
            return
        }
        try? AudioDeviceManager.setDefaultOutputDevice(id: device.id)
        FileLog.log("share: default output restored to \(uid)")
    }
}
