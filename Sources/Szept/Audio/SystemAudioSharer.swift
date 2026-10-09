import Foundation
import CoreAudio
import AudioUnit

/// Owns the system-audio sharing session: a visible multi-output device
/// (speakers + BlackHole 16ch) that becomes the system default output, a
/// dedicated HAL input unit reading BlackHole back, and the mix bus
/// feeding that audio into the mic render path (post-filters, by design).
///
/// Session-scoped: never persisted, never auto-enabled. Sharing is always
/// OFF across launches; only the previous-output UID is saved, as
/// operational state for crash recovery.
///
/// Deadlock invariant (I1): round 11 - the MIC path no longer
/// contributes ANY default-output client either: its input unit is
/// pinned to the mic interface and its output unit is pinned to its own
/// target, so the stop-before-destroy ordering is retained only as belt
/// and braces. Historically the mic engine was UNPINNED, so its muted
/// output unit was an implicit HAL client of whatever the default output
/// was, and the share teardown had to stop it BEFORE destroying the
/// multi-output (destroying a device an audio unit still references can
/// deadlock a teardown against a wedged HAL plugin). Round 10: the share
/// capture side contributes NO default-output client - it is an
/// input-only HAL unit (output element disabled) with no render graph.
///
/// Hang invariant (I5): no engine/HAL mutation API is ever called on main
/// once launch cleanup has run (cleanupStaleDevices is the sanctioned
/// pre-engine exception - it runs before the lifecycle observer and any
/// engine exist). Every one of the mutation APIs can park indefinitely
/// (dispatch_sync onto an IO unit queue that a device reconfiguration
/// holds): hang #2 was
/// inputNode.outputFormat(forBus: 0) parking main after our own pin.
/// Therefore both enable and disable do their engine/HAL work on a
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
/// the device. The E1-E3 hardening (worker-local engine rollback,
/// identity-guarded transfer releases, generation-guarded finish)
/// stands. Prevention shrinks the park window; the watchdog contains
/// the rest.
///
/// Round 10: the v0.4.0/v0.4.1 crash class (engine converter-chain
/// validation, prod-only, cause not observable from our side) is removed
/// BY CONSTRUCTION: the share capture path no longer contains an
/// AVAudioEngine - no graph, no nodes, no converters, no validators. The
/// capture unit is a bare HALOutput AudioUnit driven by one C render
/// callback straight into the mix bus; the only engine left in the app is
/// the mic processor's. I5 park surfaces shrink accordingly: component
/// New, property sets, AudioUnitInitialize, AudioOutputUnitStart, and
/// ComponentInstanceDispose - all FileLog-bracketed, watchdog intact.
///
/// Prevention layer (as of round 3): ZERO node-format queries anywhere on
/// the enable path. hang #2 was outputFormat(forBus:), hang #3 was
/// connect(format: nil) resolving the input node's HW format - both are
/// the same GetClientFormat sync through the unit's internal
/// serialization. All wiring formats are pre-built from park-safe
/// device-object HAL reads (see AudioDeviceManager.inputStreamFormat); a
/// mismatch is absorbed by an engine-inserted converter. The stale-worker
/// path performs a REAL quiet rollback (unit stop, multi-output destroy,
/// state clear) and clears the wedge latch, so a worker that eventually
/// unparks leaves the sharer usable instead of stuck-restart-only.
///
/// Prevention layer (as of round 4): hang #4 was an apply-class park -
/// connect(format:) applying a client format onto MID-UNSTACK state (the
/// BlackHole still reconfiguring +2s after a teardown; observable symptom:
/// the input-scope ASBD reads 1ch when healthy is 2ch). The full stack is:
/// post-teardown cooldown -> rate-settle wait -> pin -> input-ASBD
/// stability probe -> explicit client formats. Containment is unchanged:
/// worker queue + 8s watchdog + stale gates + wedge hygiene.
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
/// the mix bus arms after engine start with the probed capture rate, and
/// a ratio guard (captureRate/renderRate within [0.75, 1.5], code 39)
/// bounds the servo's linear-SRC operating range instead of aliasing on
/// an exotic leftover rate.

/// Real-time state for the share capture callback. Plain final class: the
/// render callback is a bare C function with NO ObjC entry, so the context
/// must not be touchable as an ObjC object (a Swift class with any
/// @objc-visible member gets a runtime header the callback path must
/// never traverse; a plain final class without @objc exposure has none
/// that AudioUnit touches). RT rules: the callback takes NO locks, does NO
/// allocation, and touches NO ObjC runtime - it renders into the
/// preallocated AudioBufferList and pushes raw pointers into the mix
/// bus's lock-free ring; that is all. The context is handed to the unit
/// as a refCon via Unmanaged.passUnretained: the sharer owns the context
/// for the unit's whole lifetime and disposes the unit before dropping
/// the context, so the callback can never observe a dead refCon.
fileprivate final class CaptureContext {
    /// The capture unit. The sharer's worker frame also holds it; kept
    /// here so the callback's ownership story is one object. Written once
    /// at build time (before the callback can ever run: the refCon is
    /// registered in the same build sequence), read-only in the callback.
    nonisolated(unsafe) var unit: AudioComponentInstance?
    let channels: Int
    let mixBus: SystemMixBus

    /// Preallocated capture list, shaped to the PROBED device format:
    /// BlackHole delivers INTERLEAVED (verified on-device: one buffer,
    /// all channels packed), so the default shape is a single buffer of
    /// `channels` x 4096 frames x Float32; the non-interleaved shape
    /// (one mono buffer per channel) is kept for devices that declare it.
    /// Built ONCE at build time; the callback only fills it.
    let bufferListPtr: UnsafeMutableRawPointer
    let capacityFrames: UInt32 = 4096
    let interleaved: Bool

    /// Scratch deinterleave targets for the interleaved path (ch0/ch1
    /// strided out before the mix-bus push). Preallocated: RT no-alloc.
    let scratchL: UnsafeMutablePointer<Float>
    let scratchR: UnsafeMutablePointer<Float>

    /// Written by the render callback (single word stores), read and
    /// logged only in stopCaptureUnit AFTER the unit is stopped (so no
    /// concurrent writer remains). Nonisolated(unsafe) by design; the
    /// write/read ordering is the unit lifetime itself.
    nonisolated(unsafe) var lastRenderStatus: OSStatus = 0
    nonisolated(unsafe) var overflowCount: Int = 0
    /// Per-render error COUNT (lastRenderStatus only keeps the last
    /// code). A start transient errors once; a real shape mismatch
    /// (cached format stale) errors on EVERY render and hits 100 within
    /// ~2s of audio - that is the signal that clears the format cache.
    nonisolated(unsafe) var renderErrorCount: Int = 0

    init(channels: Int, interleaved: Bool, mixBus: SystemMixBus) {
        self.channels = channels
        self.interleaved = interleaved
        self.mixBus = mixBus
        self.scratchL = .allocate(capacity: 4096)
        self.scratchR = .allocate(capacity: 4096)
        let listSize: Int
        if interleaved {
            listSize = MemoryLayout<AudioBufferList>.size
        } else {
            listSize = MemoryLayout<AudioBufferList>.size
                + (channels - 1) * MemoryLayout<AudioBuffer>.stride
        }
        let dataSize = 4096 * channels * MemoryLayout<Float>.size
        let total = listSize + dataSize
        bufferListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: total, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        memset(bufferListPtr, 0, total)
        let buffers = UnsafeMutableAudioBufferListPointer(
            bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
        )
        var dataOffset = listSize
        if interleaved {
            // One buffer, all channels interleaved - BlackHole's native
            // delivery shape (AudioUnitRender validates the list against
            // the device format; a mismatch is -50 paramErr).
            buffers.count = 1
            buffers[0] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(dataSize),
                mData: bufferListPtr + dataOffset
            )
        } else {
            buffers.count = channels
            for i in 0..<channels {
                buffers[i] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(4096 * MemoryLayout<Float>.size),
                    mData: bufferListPtr + dataOffset
                )
                dataOffset += 4096 * MemoryLayout<Float>.size
            }
        }
    }

    deinit {
        bufferListPtr.deallocate()
        scratchL.deallocate()
        scratchR.deallocate()
    }
}

/// The share capture render callback: a STORED C function pointer, NOT a
/// closure over self (no context capture means no ObjC, no allocation, no
/// locking on the RT thread). Renders bus 1 element 0 into the context's
/// preallocated list, then pushes into the mix bus's lock-free ring. On
/// AudioUnitRender error: record lastRenderStatus and return noErr -
/// never fail the unit over one bad render.
fileprivate let captureInputCallback: AURenderCallback = { refCon, _, inTimeStamp, _, inNumberFrames, _ -> OSStatus in
    let context = Unmanaged<CaptureContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let captureUnit = context.unit else { return noErr }
    // Clamp to the preallocated capacity; count the overflow instead of
    // growing (RT: no allocation).
    let frames = Int(inNumberFrames)
    var clipped = false
    var frameCount = frames
    if frames > Int(context.capacityFrames) {
        frameCount = Int(context.capacityFrames)
        clipped = true
    }
    var renderFlags = AudioUnitRenderActionFlags()
    let list = UnsafeMutablePointer<AudioBufferList>(OpaquePointer(context.bufferListPtr))
    let status = AudioUnitRender(
        captureUnit,
        &renderFlags, inTimeStamp, 1, UInt32(frameCount), list
    )
    if status != noErr {
        context.lastRenderStatus = status
        context.renderErrorCount += 1
        return noErr
    }
    if clipped {
        context.overflowCount += 1
    }
    guard frameCount > 0 else { return noErr }
    let abl = UnsafeMutableAudioBufferListPointer(list)
    guard abl.count > 0, let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }
    if context.interleaved {
        // BlackHole's native shape: one buffer, channels interleaved.
        // Stride ch0/ch1 out into the preallocated scratch pair (RT:
        // no allocation), then push. Mono devices push ch0 directly.
        let stride = context.channels
        if stride >= 2 {
            let l = context.scratchL
            let r = context.scratchR
            var i = 0
            while i < frameCount {
                l[i] = data[i * stride]
                r[i] = data[i * stride + 1]
                i += 1
            }
            context.mixBus.pushStereo(ch0: l, ch1: r, count: frameCount)
        } else {
            context.mixBus.push(samples: data, count: frameCount)
        }
    } else if context.channels >= 2, abl.count > 1, let ch1 = abl[1].mData?.assumingMemoryBound(to: Float.self) {
        context.mixBus.pushStereo(ch0: data, ch1: ch1, count: frameCount)
    } else {
        context.mixBus.push(samples: data, count: frameCount)
    }
    return noErr
}

@Observable
final class SystemAudioSharer {

    static let multiOutputUID = AudioDeviceManager.shareMultiOutputUID
    private static let previousOutputKey = "systemAudioPreviousOutputUID"

    /// Worker queue for every engine/HAL mutation (invariant I5). Main
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
    /// from this stamp: every observed park (hangs #3, #4) was an engine
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

    /// The live capture unit + its RT context. Queue-confined state:
    /// written by performEnable on shareQueue after a successful start,
    /// read and cleared by performDisable/performTeardown on the SAME
    /// serial queue - no hops, no races. (Round 10: replaces the
    /// main-published currentEngine; an AudioComponentInstance is an
    /// opaque pointer, so there is nothing to dealloc-transfer.)
    private var activeUnit: AudioComponentInstance?
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
    /// parameter. Needed by teardown to stop the mic engine in the safe
    /// order (before the multi-output is destroyed).
    private weak var micProcessor: MicProcessor?

    /// Injected by AppState: restarts the mic engine after a teardown that
    /// stopped it (cycleMic). Invoked on the main thread.
    var restartMicAfterShareTeardown: (() -> Void)?

    // MARK: - Enable

    /// Ordered enable with full rollback on any failure. Main-thread entry:
    /// validates state, publishes isBusy, arms the watchdog (entry-side:
    /// the queue body must never run unwatched), and dispatches the real
    /// work to shareQueue (invariant I5); the worker re-arms after its
    /// bounded cooldown to supervise real work. The capture unit is
    /// built and started BEFORE the multi-output exists, pinned to the
    /// STANDALONE BlackHole device, so the unit never has a reference to
    /// a device being created/destroyed under it (round-9 order):
    /// 1. resolve BlackHole 16ch (required); NO rate set - capture follows
    ///    the device's native rate
    /// 2. save the current default output UID (stale-share cleanup first)
    /// 3. build + start the capture unit pinned to the standalone BlackHole
    /// 4. arm the mix bus, using the probe's capture rate (after unit
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

    /// The enable body. Runs on shareQueue (invariant I5): every engine or
    /// HAL mutation happens here, never on main. All published state flips
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
        var unit: AudioComponentInstance?
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
            // BlackHole that is not the mic engine's own output device and
            // exposes at least 2 input channels.
            let allDevices = (try? AudioDeviceManager.allDevices()) ?? []
            let blackHoles = allDevices.filter { $0.name.localizedCaseInsensitiveContains("BlackHole") }
            var bh16 = blackHoles.first {
                $0.name.localizedCaseInsensitiveContains("BlackHole")
                    && $0.name.localizedCaseInsensitiveContains("16")
                    // Shared-member invariant: never pick the device the mic
                    // engine already feeds; the same BlackHole must never sit
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
            // From here the worker owns a started unit; bind the locals
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
            // has no engine and every unit is pinned to its own target
            // (I6), so this flip is structurally invisible to the rest of
            // the pipeline.
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
            // engine never referenced the multi-output, so it must NOT be
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
        // An AudioComponentInstance is an opaque pointer: dropping the
        // worker frame's copy deallocates NOTHING. There is no engine
        // dealloc park class here; disposal is explicit and bracketed in
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
                                     unit: AudioComponentInstance,
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

    /// Park-safety gate for the connect: wait until the device's input ASBD
    /// is sane, stable, AND >= 2ch before a client format is applied onto
    /// it (park class of hang #4; see the class doc's round-4/5 notes).
    /// Reads go through AudioDeviceManager.inputStreamFormat (device-
    /// object, park-safe). The first sane >=2ch read is trusted outright
    /// (probe-on-suspicion); otherwise re-read every 100ms up to
    /// formatProbeCap (4.0s), accepting two consecutive identical sane
    /// reads with the accepted read >= 2ch. At cap expiry: log and THROW
    /// code 38 (the caller performs one in-band 2s auto-retry). Never
    /// returns nil: read failures run to the cap and throw 38 exactly
    /// like sub-healthy reads - a device we cannot read sanely is a
    /// device we must not connect onto. The callback's runtime mono branch
    /// stays (harmless); nothing wires mono here.
    /// Capture-format cache codec: "rate,channels,interleaved(0|1)".
    /// The cache exists because in-process stream-format reads poison
    /// after the first capture-unit teardown (see startCaptureUnit).
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

    /// Build, enable, pin, wire, and start the share capture unit: a bare
    /// HALOutput AudioUnit, input-only, with one C render callback feeding
    /// the mix bus. No AVAudioEngine, no graph, no converters - the
    /// v0.4.0/v0.4.1 crash class (engine converter-chain validation) is
    /// removed by construction. Runs on shareQueue. Every park-capable
    /// call is FileLog-bracketed so a post-mortem shows exactly which call
    /// parked. Returns the started unit, its RT context, and the probe's
    /// ASBD rate (the SOLE rate authority: the stream the callback
    /// actually delivers).
    private func startCaptureUnit(blackHoleID: AudioDeviceID) throws -> (unit: AudioComponentInstance, context: CaptureContext, captureRate: Double) {
        // (0) Rate/channel authority. FIRST enable in a fresh process:
        // probe the device object (sane, stable read). Every LATER enable:
        // use the persisted cache. Ordering and caching are both
        // load-bearing, verified 2026-10-09: (a) an input-only client with
        // no client format set makes the HAL report a degenerate 1ch
        // stream for the PINNED device, so the probe must run before any
        // client exists; (b) after the first capture unit teardown, the
        // process's OWN reads of the device stream format return that same
        // phantom 1ch FOREVER (10+ min observed) while every other
        // process reads a healthy 16 ch on both scopes - a per-process
        // HAL cache our own client history poisons. A cached format makes
        // later enables independent of the poisoned read; the callback
        // already degrades gracefully (render status recorded, silence)
        // if the real format ever drifted from the cache, and a -50
        // (paramErr shape mismatch) clears the cache for a fresh probe.
        let cacheKey = "shareCaptureFormatCache"
        var rate: Double = 0
        var channels = 0
        var interleaved = true
        var source = ""
        if let cached = UserDefaults.standard.string(forKey: cacheKey),
           let parsed = parseCaptureFormat(cached) {
            (rate, channels, interleaved) = parsed
            source = "cached"
            FileLog.log("share: [fmt] capture format \(Int(rate)) Hz, \(channels) ch \(interleaved ? "interleaved" : "non-interleaved") (\(source)) - probe skipped (in-process reads poison after first teardown)")
        } else {
            let probed = try probeStableInputFormat(deviceID: blackHoleID)
            rate = probed.asbd.mSampleRate
            channels = Int(probed.asbd.mChannelsPerFrame)
            interleaved = probed.asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            source = probed.source
            UserDefaults.standard.set(captureFormatString(rate: rate, channels: channels, interleaved: interleaved), forKey: cacheKey)
            FileLog.log("share: [fmt] capture format \(Int(rate)) Hz, \(channels) ch \(interleaved ? "interleaved" : "non-interleaved") (\(source)) - device-native, no client format set")
        }

        // (1) Component resolution + instance creation.
        FileLog.log("share: [start capture unit] finding HALOutput component (park-capable)")
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "Szept", code: 33,
                          userInfo: [NSLocalizedDescriptionKey: "HALOutput audio component not found"])
        }
        FileLog.log("share: [start capture unit] creating component instance (park-capable)")
        var newUnit: AudioComponentInstance?
        let newInstanceStatus = AudioComponentInstanceNew(component, &newUnit)
        FileLog.log("share: [start capture unit] component instance created")
        guard newInstanceStatus == noErr, let halUnit = newUnit else {
            throw AudioDeviceError.queryFailed(newInstanceStatus)
        }

        // (2) Input-only wiring: aurioTouch / QA1533 pattern - enable the
        // input element (scope Input, element 1), disable the output
        // element (scope Output, element 0). buildOutputUnit in
        // MicProcessor's world is the mirror image. The share unit
        // therefore contributes NO client on the default output (I1).
        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        FileLog.log("share: [start capture unit] enabling input element (park-capable)")
        var st = AudioUnitSetProperty(
            halUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(halUnit)
            throw AudioDeviceError.queryFailed(st)
        }
        FileLog.log("share: [start capture unit] disabling output element (park-capable)")
        st = AudioUnitSetProperty(
            halUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(halUnit)
            throw AudioDeviceError.queryFailed(st)
        }

        // (3) Pin to the STANDALONE BlackHole. Direct device open on a
        // quiescent device nothing references yet is universally supported
        // for a pin+start. The private-mini-aggregate escape hatch is
        // deliberately NOT adopted; use it only if a retest shows pin/start
        // failure on the quiescent device. (Round 9: the settle wait that
        // used to live in step 1 is gone with the rate set - there is no
        // manufactured reconfiguration for this pin to race; the
        // post-teardown cooldown and the probe cover the residual windows.)
        var bhID = blackHoleID
        FileLog.log("share: [start capture unit] pinning device (park-capable)")
        st = AudioUnitSetProperty(
            halUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &bhID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        FileLog.log("share: [start capture unit] pin done")
        guard st == noErr else {
            AudioComponentInstanceDispose(halUnit)
            throw AudioDeviceError.queryFailed(st)
        }

        // (4) Probe ran as step (0), before any client pinned the device
        // (see the ordering rationale there). The probed channel count
        // shaped the context below.

        // (5) No ASBD to build: macOS 26.2's HAL unit rejects client
        // formats on the input element outright (kAudioUnitErr_PropertyNotWritable,
        // -10865, verified empirically on-device), and none is needed -
        // the unit delivers the DEVICE'S OWN stream format by default,
        // the same one the probe read and the context preallocates for.
        // No format negotiation: no converter, no validator, nothing for
        // Apple's render-path validation to trip over. (The engine-era
        // connect did this negotiation under the hood - that converter
        // edge was the prod crash site.)

        // (6) The input callback, refCon via passUnretained (the sharer
        // owns the context and disposes the unit before dropping it).
        let context = CaptureContext(channels: channels, interleaved: interleaved, mixBus: mixBus)
        context.unit = halUnit
        var callbackStruct = AURenderCallbackStruct(
            inputProc: captureInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        st = AudioUnitSetProperty(
            halUnit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Input, 1, &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(halUnit)
            throw AudioDeviceError.queryFailed(st)
        }

        // (7) NO client-format set: macOS 26.2's HAL unit rejects client
        // formats on the input element outright (kAudioUnitErr_PropertyNotWritable,
        // verified empirically; the engine-era connect did this work under
        // the hood and is where the prod crash lived). The unit delivers
        // the DEVICE'S OWN stream format by default - the same one the
        // probe read and the context preallocated for - so there is
        // nothing to negotiate: no converter, no validator, no mismatch.
        // If the device's format ever shifts under us mid-flight, the
        // callback's AudioUnitRender reports it and we degrade to silence
        // (lastRenderStatus) rather than crash.

        // (8) Initialize the unit.
        FileLog.log("share: [start capture unit] initializing unit (park-capable)")
        st = AudioUnitInitialize(halUnit)
        FileLog.log("share: [start capture unit] unit initialized")
        guard st == noErr else {
            AudioComponentInstanceDispose(halUnit)
            throw AudioDeviceError.queryFailed(st)
        }

        // (9) Start pulling (replaces engine.start()).
        FileLog.log("share: [start capture unit] starting unit (park-capable)")
        st = AudioOutputUnitStart(halUnit)
        FileLog.log("share: [start capture unit] unit started")
        guard st == noErr else {
            AudioUnitUninitialize(halUnit)
            AudioComponentInstanceDispose(halUnit)
            throw AudioDeviceError.queryFailed(st)
        }

        // (10)
        FileLog.log("share: [start capture unit] started, \(Int(rate)) Hz \(channels) ch")
        return (halUnit, context, rate)
    }

    // MARK: - Disable

    /// Idempotent teardown. Main-thread entry: publishes isSharing=false
    /// SYNCHRONOUSLY (the sleep path and the UI depend on it), then
    /// dispatches the engine/HAL work to shareQueue (invariant I5).
    /// RESTORE BEFORE DESTROY: the default output is moved back to the
    /// saved device while the multi-output still exists, so the restore can
    /// never dangle on a destroyed device. The mic engine is stopped (and
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
    /// deadlock invariant I1 (see the class comment): the only engine that
    /// can reference the multi-output (via the default output) is the MIC
    /// engine, and it is stopped BEFORE the multi-output is destroyed; the
    /// share unit is input-only and contributes no default-output client,
    /// so it goes down first simply as wind-down. Runs on shareQueue. One
    /// FileLog line per step plus park brackets, mirroring the
    /// enable/disable log names.
    /// - cycleMic=false is for the enable-catch, where the default flip
    ///   never succeeded and the mic engine never referenced the
    ///   multi-output, so it must not be stopped.
    private func performTeardown(gen: Int, reason: String,
                                 restartMic: Bool, cycleMic: Bool,
                                 unit: AudioComponentInstance?,
                                 context: CaptureContext?,
                                 multiOutputID: AudioDeviceID?,
                                 memberDeviceID: AudioDeviceID?) {
        // 1. Stop and dispose the share capture unit (explicit, bracketed;
        // an AudioComponentInstance is an opaque pointer - no dealloc
        // transfer story exists).
        stopCaptureUnit(unit: unit, context: context, label: reason)
        if activeUnit == unit { activeUnit = nil }
        if activeContext === context { activeContext = nil }

        // 2. Stop the mic engine: it is unpinned, so its muted output unit
        // is an implicit HAL client of the multi-output (the current
        // default). Zero live clients must remain before the destroy.
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

        // 7. Restart the mic engine if this teardown stopped it (on main),
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
    private func discardPartialUnit(unit: AudioComponentInstance?,
                                    context: CaptureContext?, label: String) {
        guard let unit else { return }
        stopCaptureUnit(unit: unit, context: context, label: label)
        FileLog.log("share: [\(label)] partial capture unit discarded")
    }

    /// Stop, uninitialize, and dispose a share capture unit, with park
    /// brackets around every HAL call, then log the callback's health
    /// counters (written by the RT callback, read only here - the unit is
    /// already stopped, so no concurrent writer remains). Runs on
    /// shareQueue.
    private func stopCaptureUnit(unit: AudioComponentInstance?,
                                 context: CaptureContext?, label: String) {
        guard let unit else { return }
        FileLog.log("share: [\(label)] stopping capture unit (park-capable)")
        let stopStatus = AudioOutputUnitStop(unit)
        FileLog.log("share: [\(label)] capture unit stopped")
        if stopStatus == noErr {
            FileLog.log("share: [\(label)] uninitializing capture unit (park-capable)")
            AudioUnitUninitialize(unit)
            FileLog.log("share: [\(label)] capture unit uninitialized")
            FileLog.log("share: [\(label)] disposing capture unit (park-capable)")
            AudioComponentInstanceDispose(unit)
            FileLog.log("share: [\(label)] capture unit disposed")
        }
        if let context {
            if context.lastRenderStatus != 0 {
                FileLog.log("share: [\(label)] capture renders errored \(context.lastRenderStatus) during session (\(context.renderErrorCount) renders)")
                if context.lastRenderStatus == -50 && context.renderErrorCount > 100 {
                    // paramErr on MOST renders = the delivered stream shape
                    // mismatched the allocated context: the cached format
                    // is stale (e.g. the device was reconfigured in Audio
                    // MIDI Setup). A single -50 is a known start transient
                    // (first pull before the device streams) and must NOT
                    // clear the cache - doing so re-exposes every later
                    // enable to the poisoned in-process format read.
                    UserDefaults.standard.removeObject(forKey: "shareCaptureFormatCache")
                    FileLog.log("share: [\(label)] capture format cache cleared (persistent shape mismatch)")
                }
            }
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
    /// still busy when it fires, the worker is parked in an engine/HAL
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
    /// observer is created and the engine starts. Finds share multi-output
    /// leftovers from a crashed session; if one is still the default
    /// output, restore the saved previous device (if resolvable), then
    /// destroy every match. Sanctioned I5 exception: this is the one
    /// main-thread HAL mutation, allowed because it runs pre-engine and
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
