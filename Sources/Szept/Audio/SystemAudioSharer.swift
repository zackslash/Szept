import Foundation
import AVFoundation
import CoreAudio

/// Owns the system-audio sharing session: a visible multi-output device
/// (speakers + BlackHole 16ch) that becomes the system default output, a
/// capture engine reading BlackHole back, and the mix bus feeding that
/// audio into the mic render path (post-filters, by design).
///
/// Session-scoped: never persisted, never auto-enabled. Sharing is always
/// OFF across launches; only the previous-output UID is saved, as
/// operational state for crash recovery.
///
/// Deadlock invariant (I1): the mic engine is UNPINNED, so its muted output
/// unit is an implicit HAL client of whatever the default output is. The
/// share teardown therefore stops the mic engine BEFORE destroying the
/// multi-output (see performTeardown): destroying a device an audio unit
/// still references can deadlock main in AVAudioEngine dealloc against a
/// wedged HAL plugin. The same invariant forbids stopping the mic engine
/// first when the share is on, while the multi-output is the default: the
/// sharer teardown (which flips the default back) must run BEFORE the mic
/// engine stops, which is why callers that stop the mic call
/// disable(restartMic: false) first.
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
/// Prevention layer (as of round 3): ZERO node-format queries anywhere on
/// the enable path. hang #2 was outputFormat(forBus:), hang #3 was
/// connect(format: nil) resolving the input node's HW format - both are
/// the same GetClientFormat sync through the unit's internal
/// serialization. All wiring formats are pre-built from park-safe
/// device-object HAL reads (see AudioDeviceManager.inputStreamFormat); a
/// mismatch is absorbed by an engine-inserted converter. The stale-worker
/// path performs a REAL quiet rollback (engine stop, multi-output destroy,
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
    /// while a parked worker is wedged). UI double-dispatch guard. The
    /// watchdog clears it when it declares a wedge, so a parked worker
    /// holds it only until then.
    private(set) var isBusy = false
    var mixBus = SystemMixBus()

    /// Set by the watchdog when a transition worker parks past the 8s
    /// deadline. All transitions refuse to start while set; only a
    /// returning stale worker that rolled back cleanly clears it
    /// (clearWedgeIfStale). Otherwise only an app restart clears it (the
    /// wedged worker cannot be unwound safely).
    private(set) var shareQueueWedged = false
    /// Last-recovery message for the user (watchdog parking, etc.). The
    /// next UI toggle surfaces it via lastError.
    private(set) var userNotice: String?

    /// Main thread. AppState consumes a stuck-transition notice into its
    /// error banner; only the sharer itself ever sets the value.
    func clearUserNotice() { userNotice = nil }

    /// True between the start and end of a teardown, so a re-entrant
    /// enable() or disable() cannot interleave with one in progress.
    private var isTearingDown = false

    /// Bumped at every transition start (and by the watchdog), so a stale
    /// worker that eventually unparks cannot publish anything: every
    /// published flip from the queue is guarded by generation equality.
    private var transitionGeneration = 0

    /// When the last performTeardown returned. Enables sleep out a cooldown
    /// from this stamp: every observed park (hangs #3, #4) was an engine
    /// touch 2-5s after teardown unstack churn, so no engine/HAL touch
    /// happens inside the window. Queue-confined; this doc is the
    /// canonical cooldown rationale.
    private var lastTeardownCompletedAt: Date?
    /// 3.0 (not 2.5) covers the async mic-rebuild churn that lands after
    /// the stamp: restartMicAfterShareTeardown is dispatched at teardown
    /// end, so the rebuild's own engine/HAL work trails the timestamp.
    private static let postTeardownCooldown: TimeInterval = 3.0

    /// Probe cap for the input-ASBD stability wait (round-5 evidence: the
    /// unstack outlasted the 3s cooldown's ~2s effective remainder plus the
    /// old 1.5s cap, so the cap now terminates in REFUSAL - code 38, one
    /// in-band auto-retry - which makes a longer cap safe). Cadence is
    /// unchanged at 100ms. Coupled budget: the code-38 retry's 2s settle
    /// plus this cap must stay under the 8s watchdog - the retry's second
    /// attempt gets no later re-arm. Bump the settle, this cap, and the
    /// watchdog together.
    private static let formatProbeCap: TimeInterval = 4.0

    /// Bumped on every armWatchdog call, main-confined alongside
    /// transitionGeneration: a newer arm supersedes (invalidates) every
    /// earlier pending watchdog timer.
    private var watchdogEpoch = 0

    /// The live capture engine, recreated FRESH per enable (AVAudioEngine
    /// restart-after-stop is flaky). Exposed so the lifecycle observer can
    /// match a configuration-change notification by object identity.
    /// Main-confined: the worker assigns it via main hops only.
    private(set) var currentEngine: AVAudioEngine?
    private(set) var multiOutputID: AudioDeviceID?
    /// The multi-output's BlackHole member, exposed so a mic rebuild can
    /// detect a member collision (the same BlackHole in both the private
    /// aggregate and the multi-output is the forbidden configuration).
    private(set) var memberDeviceID: AudioDeviceID?
    /// The render rate the mix bus servo was armed with (set in enable()).
    /// A rate-changing mic rebuild must re-enable the share instead of
    /// leaving the servo at a stale nominal ratio.
    private(set) var armedRenderRate: Double?
    /// When the capture engine STARTED (not when the share finished
    /// enabling). Guards the config-change handler against start-time
    /// configuration changes; because it is set at engine start, the grace
    /// window also covers the later multi-output membership change.
    private var enabledAt: Date?

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
    /// bounded cooldown to supervise real work. The capture engine is
    /// built and started BEFORE the multi-output exists, pinned to the
    /// STANDALONE BlackHole device, so the engine never has a reference to
    /// a device being created/destroyed under it (round-9 order):
    /// 1. resolve BlackHole 16ch (required); NO rate set - capture follows
    ///    the device's native rate
    /// 2. save the current default output UID (stale-share cleanup first)
    /// 3. build + start the capture engine pinned to the standalone BlackHole
    /// 4. arm the mix bus, using the probe's capture rate (after engine
    ///    start; safe because pushes no-op into an unarmed bus = silence)
    /// 5. create the multi-output (speakers main, BlackHole member)
    /// 6. suppression window, flip the default output to the multi-output
    /// 7. isSharing = true (last)
    @MainActor
    func enable(micProcessor: MicProcessor) async throws {
        guard !isSharing else { return }
        if shareQueueWedged {
            FileLog.log("share: enable refused, share queue wedged (app restart required)")
            throw NSError(domain: "Szept", code: 37,
                          userInfo: [NSLocalizedDescriptionKey: "Sharing stopped after a snag and needs an app restart. Everything else keeps working."])
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
        // Armed at ENTRY, not only in the worker: if the queue is wedged
        // unlatched (an unwatched exit-path dealloc park), the worker never
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

        // Snapshot the published state synchronously on main, as disable
        // does: later worker hops must not race the teardown's decisions.
        let engine = currentEngine
        let multiOutputID = multiOutputID
        let memberDeviceID = memberDeviceID
        mixBus.disarm()
        FileLog.log("share: re-enable sequence")

        shareQueue.async { self.performReenable(
            gen: gen, micProcessor: micProcessor,
            engine: engine, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        ) }
    }

    /// The enable body. Runs on shareQueue (invariant I5): every engine or
    /// HAL mutation happens here, never on main. All published state flips
    /// hop to main, guarded by the transition generation; a stale
    /// generation means the watchdog already gave up on us, so we roll
    /// back quietly and flip nothing.
    private func performEnable(_ gen: Int, _ micProcessor: MicProcessor) {
        var step = "suppression"
        var multiOutputID: AudioDeviceID?
        var memberDeviceID: AudioDeviceID?
        var defaultFlipped = false
        // The worker's own engine reference. startCaptureEngine returns a
        // started engine or throws, so every stale gate below sees it
        // non-nil (bound non-optionally after the retry block).
        var engine: AVAudioEngine?

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
            // Suppression FIRST, before any default-output flip this call
            // may trigger (including the stale-cleanup restore in step 3):
            // the window is time-based, so opening it early is harmless and
            // closing it late is impossible to get wrong. The write is
            // main-confined; the async hop costs microseconds, well inside
            // the 1.5s window.
            DispatchQueue.main.async { self.beginSuppression() }

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
            // startCaptureEngine is the sole rate authority.
            let deviceRate = AudioDeviceManager.nominalSampleRate(deviceID: blackHole.id) ?? 48000
            FileLog.log("share: [resolve BlackHole] capturing at device rate \(Int(deviceRate)) Hz (no rate set)")

            step = "save previous output"
            // 3. Persist the current default output. If the current default
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

            step = "start capture engine"
            // 3. Build + start the capture engine pinned to the STANDALONE
            // BlackHole, before the multi-output exists. One retry after a
            // 250 ms settle for residual races. The retry catches
            // HAL-REFUSED THROWS only: a park does not throw, it just never
            // returns; the watchdog owns those.
            self.micProcessor = micProcessor
            var captureRate: Double = 48000
            do {
                (engine, captureRate) = try startCaptureEngine(blackHoleID: blackHole.id)
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
                    FileLog.log("share: [\(step)] capture engine start failed (\(error.localizedDescription)), retrying once after 250ms")
                    armWatchdog(gen)
                    discardPartialEngine(label: step)
                    usleep(250_000)
                }
                (engine, captureRate) = try startCaptureEngine(blackHoleID: blackHole.id)
            }
            // The grace clock starts at engine start, so it also covers the
            // multi-output creation + default flip below.
            publishIfCurrent(gen) { self.enabledAt = Date() }
            // From here the worker owns a started engine; bind it
            // non-optionally for the gates and the rollback path.
            guard let engine else {
                throw NSError(domain: "Szept", code: 33,
                              userInfo: [NSLocalizedDescriptionKey: "Capture engine did not start"])
            }

            step = "arm mix bus"
            // 4. Arm the mix bus AFTER the engine start (round 9 reorder):
            // single rate authority - captureRate comes from the probe's
            // ASBD (the stream the tap actually delivers), not from a
            // separate nominalSampleRate read (the latent disagreement this
            // kills). Arming this late is safe: the tap's push no-ops while
            // the ring is nil (guard let ring), drainRing cannot mix before
            // the active flag flips; the few ms of capture that landed in a
            // not-yet-armed bus are silence. The ratio guard bounds the
            // linear-SRC servo's operating range instead of aliasing on an
            // exotic leftover rate.
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
            // while the engine start parked. Before creating anything new,
            // roll back quietly with the local state. defaultFlipped is
            // constant false here (and at gate 2): both gates precede the
            // irreversible flip; gate 3, after it, passes true.
            if isStale(gen) { return rollbackStaleWorker(gen: gen, step: step, defaultFlipped: false, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID, engine: engine) }

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
            if isStale(gen) { return rollbackStaleWorker(gen: gen, step: step, defaultFlipped: false, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID, engine: engine) }

            step = "flip default output"
            // 6. Suppression window again: flipping the default output makes
            // the mic engine's muted output unit fire a configuration change
            // that would otherwise trigger a full mic rebuild
            // mid-presentation. The window self-expires (~1.5s); it is never
            // closed early so the async change lands inside it.
            DispatchQueue.main.async { self.beginSuppression() }
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
            if isStale(gen) { return rollbackStaleWorker(gen: gen, step: step, defaultFlipped: true, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID, engine: engine) }

            // 7. Published last: the UI and the render path only see the
            // share once engine, device flip, and mix bus are all live.
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
                engine: currentEngineSnapshot(),
                multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
            )
            // Surface the failure to the user on main.
            DispatchQueue.main.async {
                if gen == self.transitionGeneration {
                    self.userNotice = ns.localizedDescription
                }
            }
        }
        // Drop the worker's own engine reference (watched, on the queue,
        // before the transition ends): the teardown above released main's
        // reference, so this frame holds the last one and its dealloc is
        // park-capable.
        if engine != nil {
            FileLog.log("share: [enable rollback] releasing worker engine (park-capable)")
            engine = nil
            FileLog.log("share: [enable rollback] worker engine released")
        }
        finishTransition(gen: gen)
    }

    /// Sequenced re-enable body (see reenable). Runs on shareQueue:
    /// disable-equivalent teardown, then a fresh enable under a NEW
    /// generation with its own watchdog budget, all inside the ONE isBusy
    /// window the entry opened.
    private func performReenable(gen: Int, micProcessor: MicProcessor,
                                 engine: AVAudioEngine?,
                                 multiOutputID: AudioDeviceID?,
                                 memberDeviceID: AudioDeviceID?) {
        performTeardown(
            gen: gen, reason: "re-enable",
            restartMic: true, cycleMic: true,
            engine: engine, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        )
        if isStale(gen) { clearWedgeIfStale(gen) }
        // Drop the worker's own engine reference (watched) before the
        // fresh enable runs.
        if engine != nil {
            FileLog.log("share: [re-enable] releasing worker engine (park-capable)")
            var held = engine
            held = nil
            FileLog.log("share: [re-enable] worker engine released")
        }
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
    /// OWN engine: under the latch protocol no newer session can exist
    /// while wedged (enable refuses), but a teardown must only release
    /// what it owns - this worker's frame reference is exactly that, and
    /// the identity guard in the teardown is belt-and-braces for it.
    private func rollbackStaleWorker(gen: Int, step: String, defaultFlipped: Bool,
                                     multiOutputID: AudioDeviceID?,
                                     memberDeviceID: AudioDeviceID?,
                                     engine: AVAudioEngine) {
        FileLog.log("share: stale worker returned (gen \(gen)); rolling back quietly (step was: \(step))")
        performTeardown(
            gen: gen, reason: "stale rollback",
            restartMic: true, cycleMic: defaultFlipped,
            engine: engine,
            multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        )
        clearWedgeIfStale(gen)
        // Drop the worker's own engine reference (watched, on the queue,
        // before the transition ends): the teardown released main's
        // reference, so this frame holds the last one.
        FileLog.log("share: [stale rollback] releasing worker engine (park-capable)")
        var held = Optional(engine)
        held = nil
        FileLog.log("share: [stale rollback] worker engine released")
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
    /// device we must not connect onto. The tap's runtime mono branch
    /// stays (harmless); nothing wires mono here.
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

    /// Build, pin, wire, and start the share capture engine. Runs on
    /// shareQueue. Every park-capable call is bracketed with FileLog lines
    /// so a post-mortem shows exactly which call parked. Returns the
    /// started engine plus the probe's ASBD rate (the SOLE rate authority:
    /// the stream the tap actually delivers); the identity is already
    /// published on main (currentEngine) before prepare/start.
    private func startCaptureEngine(blackHoleID: AudioDeviceID) throws -> (engine: AVAudioEngine, captureRate: Double) {
        FileLog.log("share: [start capture engine] creating AVAudioEngine (park-capable)")
        let engine = AVAudioEngine()
        FileLog.log("share: [start capture engine] engine created")
        // Assign BEFORE wiring: isSharing is still false, so identity-
        // matched notifications are dropped for now, and the catch's
        // teardown branch is correct from this point on. main.sync from
        // the queue is deadlock-free (see shareQueue's doc). The
        // assignment TRANSFERS the old engine out to this queue; the
        // transfer story is canonical in performTeardown.
        var retiredEngine: AVAudioEngine? = DispatchQueue.main.sync {
            let old = self.currentEngine
            self.currentEngine = engine
            return old
        }
        FileLog.log("share: [start capture engine] retiring prior engine (park-capable)")
        retiredEngine = nil
        FileLog.log("share: [start capture engine] prior engine retired")

        FileLog.log("share: [start capture engine] accessing input node (park-capable)")
        let inputNode = engine.inputNode
        guard let inputAU = inputNode.audioUnit else {
            throw NSError(domain: "Szept", code: 33,
                          userInfo: [NSLocalizedDescriptionKey: "Capture node has no underlying audio unit"])
        }
        FileLog.log("share: [start capture engine] input node accessed")
        // Direct device open on the quiescent STANDALONE BlackHole: a
        // device nothing references yet is universally supported for a
        // pin+start. The private-mini-aggregate escape hatch (building a
        // tiny throwaway aggregate around the BlackHole to satisfy picky
        // HAL states) is deliberately NOT adopted; use it only if a retest
        // shows pin/start failure on the quiescent device. (Round 9: the
        // settle wait that used to live in step 1 is gone with the rate
        // set - there is no longer a manufactured reconfiguration for this
        // pin to race; the post-teardown cooldown and the probe cover the
        // residual windows.)
        var bhID = blackHoleID
        FileLog.log("share: [start capture engine] pinning device (park-capable)")
        let pinStatus = AudioUnitSetProperty(
            inputAU, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &bhID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        FileLog.log("share: [start capture engine] pin done")
        guard pinStatus == noErr else {
            throw AudioDeviceError.queryFailed(pinStatus)
        }

        // Never an empty graph: input -> muted mixer -> output, so the
        // engine has a complete pull chain and only the tap consumes
        // the audio. NIL FORMATS ARE RETIRED: connect(format: nil) on the
        // input side resolves the SOURCE node's HW format internally -
        // the same GetClientFormat dispatch_sync that was hang #2
        // (outputFormat(forBus:)). Formats are therefore PRE-BUILT here
        // from park-safe device-object HAL reads (see the class doc's
        // round-3 note); any mismatch between the wiring format and the
        // node's real HW format is absorbed by an engine-inserted
        // converter, never by a node query.
        //
        // Sole format source: the stability probe. It gates the
        // client-format application below until the device's input ASBD
        // is sane and stable, and it THROWS on failure - there is no
        // fallback ladder.
        let probed = try probeStableInputFormat(deviceID: blackHoleID)
        let rate = probed.asbd.mSampleRate
        let channels = Int(probed.asbd.mChannelsPerFrame)
        let source = probed.source
        // Cap the WIRING format at 2ch: the tap consumes only ptrs[0]/ptrs[1]
        // (system stereo), and macOS 26.2 refuses to construct >2ch standard
        // float formats at all - AVAudioFormat(standardFormatWithSampleRate:
        // channels: 16) returns nil (verified live on the test Mac; the
        // hand-built ASBD route is nil too). The engine inserts a converter
        // from the device's full channel count; capture loses nothing.
        let wireChannels = min(channels, 2)
        FileLog.log("share: [fmt] wiring \(Int(rate)) Hz, \(wireChannels) ch from \(channels) ch (\(source))")
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(wireChannels)) else {
            throw NSError(domain: "Szept", code: 36,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build the capture wiring format"])
        }

        FileLog.log("share: [start capture engine] connecting input to mixer (park-capable)")
        engine.connect(inputNode, to: engine.mainMixerNode, format: fmt)
        FileLog.log("share: [start capture engine] input to mixer connected")
        FileLog.log("share: [start capture engine] connecting mixer to output (park-capable)")
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
        FileLog.log("share: [start capture engine] mixer to output connected")
        engine.mainMixerNode.outputVolume = 0

        FileLog.log("share: [start capture engine] installing tap (park-capable)")
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [mixBus] buffer, _ in
            guard let ptrs = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            if buffer.format.channelCount >= 2 {
                mixBus.pushStereo(ch0: ptrs[0], ch1: ptrs[1], count: frames)
            } else {
                mixBus.push(samples: ptrs[0], count: frames)
            }
        }
        FileLog.log("share: [start capture engine] tap installed")

        FileLog.log("share: [start capture engine] preparing (park-capable)")
        engine.prepare()
        FileLog.log("share: [start capture engine] prepared, starting (park-capable)")
        try engine.start()
        FileLog.log("share: [start capture engine] engine started on BlackHole id \(blackHoleID)")
        return (engine, rate)
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

        // Snapshot the published state synchronously on main: later worker
        // hops must not race the teardown's decisions.
        let engine = currentEngine
        let multiOutputID = multiOutputID
        let memberDeviceID = memberDeviceID

        // Barrier first: the render thread stops mixing immediately; the
        // ring is intentionally never freed.
        mixBus.disarm()
        FileLog.log("share: system audio sharing disabled")

        shareQueue.async { self.performDisable(
            gen: gen, restartMic: restartMic,
            engine: engine, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        ) }
    }

    /// The disable body. Runs on shareQueue (invariant I5).
    private func performDisable(gen: Int, restartMic: Bool,
                                engine: AVAudioEngine?,
                                multiOutputID: AudioDeviceID?,
                                memberDeviceID: AudioDeviceID?) {
        // Stale gate: disable's steps only UNDO, so a returning stale
        // worker still runs the teardown (restorative), but it must not
        // race a newer session - restartMic is skipped. While wedged, no
        // newer session can exist (enable refuses), so there is nothing to
        // race unless the wedge was already cleared.
        //
        // Asymmetry note (whole-saga evidence): teardown ops ON THE QUEUE
        // never parked - reader-side wind-down (removeTap/stop/release/
        // dispose) plus device-object sets (restore/destroy). The park
        // class is WRITER-side format application (startCaptureEngine
        // only); the round-6 dealloc park was a release run on MAIN, since
        // fixed by the transfer pattern. Revisit if any teardown bracket
        // ever parks.
        let stale = isStale(gen)
        if stale {
            FileLog.log("share: stale worker returned (gen \(gen)); disable teardown runs restoratively, no mic restart")
        }
        performTeardown(
            gen: gen, reason: "disable",
            restartMic: stale ? false : restartMic, cycleMic: true,
            engine: engine, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        )
        if stale { clearWedgeIfStale(gen) }
        // Drop the worker's own engine reference (watched, on the queue,
        // before the transition ends): the teardown released main's
        // reference, so this frame holds the last one.
        if engine != nil {
            FileLog.log("share: [disable] releasing worker engine (park-capable)")
            var held = engine
            held = nil
            FileLog.log("share: [disable] worker engine released")
        }
        finishTransition(gen: gen)
    }

    // MARK: - Teardown

    /// The capture-side teardown, in the exact order that keeps the
    /// deadlock invariant I1 (see the class comment): every engine that can
    /// reference the multi-output (via the default output) is stopped
    /// BEFORE the multi-output is destroyed. Runs on shareQueue. One
    /// FileLog line per step plus park brackets, mirroring the
    /// enable/disable log names.
    /// - cycleMic=false is for the enable-catch, where the default flip
    ///   never succeeded and the mic engine never referenced the
    ///   multi-output, so it must not be stopped.
    private func performTeardown(gen: Int, reason: String,
                                 restartMic: Bool, cycleMic: Bool,
                                 engine: AVAudioEngine?,
                                 multiOutputID: AudioDeviceID?,
                                 memberDeviceID: AudioDeviceID?) {
        // 1. Stop the share capture engine.
        stopShareEngine(engine, label: reason)

        // Release the engine reference by TRANSFER: the nil-assignment on
        // main would drop the last reference there and run the AVAudioEngine
        // dealloc inside the sync block (round-6 deadlock). Drop it here on
        // the share queue, bracketed - the dealloc is park-capable (it
        // tears down its IO units against a possibly-wedged plugin).
        FileLog.log("share: [\(reason)] releasing capture engine (park-capable)")
        releaseEngineOwnership(engine)
        FileLog.log("share: [\(reason)] capture engine released")

        // 2. Stop the mic engine: it is unpinned, so its muted output unit
        // is an implicit HAL client of the multi-output (the current
        // default). Zero live clients must remain before the destroy.
        var micWasStopped = false
        if cycleMic, micProcessor?.isRunning == true {
            FileLog.log("share: [\(reason)] stopping mic engine before multi-output destroy (park-capable)")
            micProcessor?.stop()
            micWasStopped = true
            FileLog.log("share: [\(reason)] mic engine stopped before multi-output destroy")
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

        // 4. Re-arm suppression around the restore flip, mirroring the
        // enable flip: it equally fires the mic engine's configuration
        // change when the mic engine is still running (cycleMic=false).
        DispatchQueue.main.async { self.beginSuppression() }

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
                self.enabledAt = nil
            }
        } else {
            publishIfCurrent(gen) {
                self.multiOutputID = nil
                self.memberDeviceID = nil
                self.armedRenderRate = nil
                self.enabledAt = nil
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

    /// Stop and discard a half-built engine from a failed start attempt
    /// (before the retry). Runs on shareQueue.
    private func discardPartialEngine(label: String) {
        guard let engine = currentEngineSnapshot() else { return }
        stopShareEngine(engine, label: label)
        FileLog.log("share: [\(label)] releasing partial capture engine (park-capable)")
        releaseEngineOwnership(engine)
        FileLog.log("share: [\(label)] partial capture engine released")
    }

    /// Identity-guarded engine release, shared by performTeardown and
    /// discardPartialEngine: nils main's currentEngine only when it still
    /// IS this teardown's engine, transfers the reference out, and drops
    /// it here on the share queue (see performTeardown's transfer note).
    /// Under the latch protocol no newer session can exist while wedged -
    /// enable refuses - so the identity guard is belt-and-braces for the
    /// rule that a teardown only releases what it owns.
    private func releaseEngineOwnership(_ engine: AVAudioEngine?) {
        var retiredEngine: AVAudioEngine? = DispatchQueue.main.sync {
            if self.currentEngine === engine {
                let old = self.currentEngine
                self.currentEngine = nil
                return old
            }
            return nil
        }
        retiredEngine = nil
    }

    private func currentEngineSnapshot() -> AVAudioEngine? {
        DispatchQueue.main.sync { self.currentEngine }
    }

    /// Stop a share capture engine, with park brackets around the two
    /// park-capable calls. Runs on shareQueue.
    private func stopShareEngine(_ engine: AVAudioEngine?, label: String) {
        guard let engine else { return }
        FileLog.log("share: [\(label)] removing tap (park-capable)")
        engine.inputNode.removeTap(onBus: 0)
        FileLog.log("share: [\(label)] tap removed")
        FileLog.log("share: [\(label)] stopping engine (park-capable)")
        engine.stop()
        FileLog.log("share: [\(label)] engine stopped")
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

    // MARK: - External change handling

    /// Engine configuration change for OUR capture engine (matched by
    /// object identity in the lifecycle observer): the BlackHole capture
    /// path broke, so tear the share down (and restart the mic, which the
    /// teardown stops to keep invariant I1).
    func handleEngineConfigChange() {
        guard isSharing else { return }
        // Grace: AVAudioEngine can post a start-time configuration change
        // as the input format finalizes; ignore those (device-list watchdog
        // covers real loss).
        if let enabledAt, Date().timeIntervalSince(enabledAt) > 2.0 {
            FileLog.log("share: capture engine config changed, disabling")
            Task { await self.disable(restartMic: true) }
        }
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

    // MARK: - Suppression window

    /// Owns the timestamp the lifecycle observer checks. Main thread only
    /// (worker writes hop to main; the hop costs microseconds, well inside
    /// the window).
    private var suppressionUntil = Date.distantPast
    private static let suppressionInterval: TimeInterval = 1.5

    var isSuppressingRebuild: Bool { Date() < suppressionUntil }

    /// Open the window around the default-output flip + capture engine start.
    private func beginSuppression() {
        suppressionUntil = Date().addingTimeInterval(Self.suppressionInterval)
    }
}
