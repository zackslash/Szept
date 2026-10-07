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
/// Hang invariant (I5): no engine/HAL mutation API is ever called on main.
/// Every one of them can park indefinitely (dispatch_sync onto an IO unit
/// queue that a device reconfiguration holds): hang #2 was
/// inputNode.outputFormat(forBus: 0) parking main after our own pin.
/// Therefore both enable and disable do their engine/HAL work on a
/// dedicated worker queue (shareQueue), main only publishes state, and an
/// 8s watchdog converts a parked worker into a self-heal: the parked
/// queue is abandoned and replaced (bounded leak: one DispatchQueue + one
/// parked thread + at most one engine per wedge, capped at three per
/// incident), the wedged session state is reset on main, and the user is
/// told to try again. Only after the heal budget is exhausted (three
/// failed heals) does sharing latch "restart the app" (code 37).
/// Prevention shrinks the park window; the watchdog contains the rest.
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
@Observable
final class SystemAudioSharer {

    static let multiOutputUID = AudioDeviceManager.shareMultiOutputUID
    private static let previousOutputKey = "systemAudioPreviousOutputUID"

    /// Worker queue for every engine/HAL mutation (invariant I5). Main
    /// never dispatches sync onto this queue, so main.sync hops from the
    /// queue back to main are deadlock-free.
    ///
    /// Var, not let: the watchdog heal REPLACES a wedged queue (its worker
    /// is parked forever). Written ONLY here on main (the heal), read ONLY
    /// from the two @MainActor entries (enable/disable). The generation
    /// suffix makes an abandoned queue attributable in spindumps.
    private var shareQueue = DispatchQueue(label: "dev.zackslash.Szept.share",
                                           qos: .userInitiated)

    private(set) var isSharing = false
    /// True while an enable/disable transition is queued or running (and
    /// while a parked worker is wedged). UI double-dispatch guard.
    private(set) var isBusy = false
    var mixBus = SystemMixBus()

    /// True only after the heal budget is exhausted (three wedges that
    /// self-healing could not clear). All transitions refuse to start
    /// while set; a returning stale worker that rolls back cleanly proves
    /// the un-wedge and resets it (clearWedgeIfStale).
    private(set) var healsExhausted = false
    /// Wedges self-healed this incident. Bumped by the watchdog heal,
    /// zeroed by a clean stale-worker rollback and by a successful enable
    /// publish; heals stop (latching restart-required) past 3.
    private var healCount = 0
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
    /// validates state, publishes isBusy, and dispatches the real work to
    /// shareQueue (invariant I5); the watchdog is armed inside the worker
    /// after its bounded cooldown. The capture engine is
    /// built and started BEFORE the multi-output exists, pinned to the
    /// STANDALONE BlackHole device, so the engine never has a reference to
    /// a device being created/destroyed under it:
    /// 1. resolve BlackHole 16ch (required) and pin it to 48 kHz
    /// 2. arm the mix bus for the two clocks
    /// 3. save the current default output UID (stale-share cleanup first)
    /// 4. build + start the capture engine pinned to the standalone BlackHole
    /// 5. create the multi-output (speakers main, BlackHole member)
    /// 6. suppression window, flip the default output to the multi-output
    /// 7. isSharing = true (last)
    @MainActor
    func enable(micProcessor: MicProcessor) async throws {
        guard !isSharing else { return }
        if healsExhausted {
            FileLog.log("share: enable refused, heal budget exhausted (app restart required)")
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
        // The watchdog is armed inside performEnable, after the cooldown:
        // it supervises real work only.
        shareQueue.async { self.performEnable(gen, micProcessor) }
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

        // Cooldown FIRST, step label "cooldown": every observed park
        // (hangs #3, #4) was an engine touch 2-5s after teardown unstack
        // churn, so sleep out the remainder of the window before touching
        // anything. The sleep is invisible to main; isBusy already holds
        // the UI. 3.0 (not 2.5) covers the async mic-rebuild churn that
        // lands after the stamp: restartMicAfterShareTeardown is dispatched
        // at teardown end, so the rebuild's own engine/HAL work trails the
        // timestamp.
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

        // Arm the watchdog AFTER the cooldown: it supervises real work
        // only; dead time (cooldown) is bounded by construction - a false
        // wedge costs an app restart and must be impossible.
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
            AudioDeviceManager.setNominalSampleRate(deviceID: blackHole.id, to: 48000,
                                                    logPrefix: "share")
            // Rate settle: our own rate set manufactures a device
            // reconfiguration; the pin in step 4 triggers it again. Poll
            // until the device reports 48 kHz (up to 500ms) so the pin does
            // not race the reconfiguration.
            var waitedMs = 0
            while AudioDeviceManager.nominalSampleRate(deviceID: blackHole.id) != 48000,
                  waitedMs < 500 {
                usleep(50_000)
                waitedMs += 50
            }
            if waitedMs > 0 {
                FileLog.log("share: [\(step)] rate settling, waited \(waitedMs)ms")
            }

            step = "arm mix bus"
            // 2. Arm the mix bus: capture at the BH16 rate we actually got
            // (read back after the best-effort 48k pin; the pin can fail),
            // render at the mic processor's output rate. Active flag is set
            // last (barrier inside).
            let inRate = AudioDeviceManager.nominalSampleRate(deviceID: blackHole.id) ?? 48000
            let renderRate = micProcessor.renderSampleRate ?? 48000
            let armedRate = renderRate
            publishIfCurrent(gen) { self.armedRenderRate = armedRate }
            mixBus.arm(inputRate: inRate, outputRate: renderRate)

            step = "save previous output"
            // 3. Persist the current default output. If the current default
            // IS a stale share device, run stale cleanup first so we never
            // save our own device as the thing to restore. A loopback
            // (BlackHole) default would mean restoring INTO a loopback and
            // hearing nothing, so refuse before persisting anything.
            if AudioDeviceManager.defaultOutputDeviceUID() == Self.multiOutputUID {
                Self.restorePreviousOutputFromDefaults()
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
            // 4. Build + start the capture engine pinned to the STANDALONE
            // BlackHole, before the multi-output exists. One retry after a
            // 250 ms settle for residual races. The retry catches
            // HAL-REFUSED THROWS only: a park does not throw, it just never
            // returns; the watchdog owns those.
            self.micProcessor = micProcessor
            var engine: AVAudioEngine?
            do {
                engine = try startCaptureEngine(blackHoleID: blackHole.id)
            } catch {
                if (error as NSError).code == 38 {
                    // Probe refusal: the device is still settling. Give it
                    // one in-band 2s auto-retry; the re-arm supersedes the
                    // first watchdog (epoch bump), since this legitimate
                    // path now runs ~10s total and would false-wedge at the
                    // first timer's +8s.
                    FileLog.log("share: device still settling, retrying once in 2s")
                    armWatchdog(gen)
                    usleep(2_000_000)
                } else {
                    FileLog.log("share: [\(step)] capture engine start failed (\(error.localizedDescription)), retrying once after 250ms")
                    // Re-arm for uniformity: the first attempt consumed
                    // part of the budget; the retry deserves a fresh 8s.
                    armWatchdog(gen)
                    discardPartialEngine(label: step)
                    usleep(250_000)
                }
                engine = try startCaptureEngine(blackHoleID: blackHole.id)
            }
            // The grace clock starts at engine start, so it also covers the
            // multi-output creation + default flip below.
            publishIfCurrent(gen) { self.enabledAt = Date() }
            _ = engine

            // STALE GATE 1: the watchdog may have abandoned this worker
            // while the engine start parked. Before creating anything new,
            // roll back quietly with the local state.
            if isStale(gen) { return rollbackStaleWorker(gen: gen, step: step, defaultFlipped: defaultFlipped, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID, engine: engine) }

            step = "create multi-output"
            // 5. Multi-output: previous default (the speakers) as clock
            // master and app-facing format, BlackHole as drift-compensated
            // member.
            guard let mainUID = AudioDeviceManager.defaultOutputDeviceUID() else {
                throw NSError(domain: "Szept", code: 31,
                              userInfo: [NSLocalizedDescriptionKey: "Could not read the current output device"])
            }
            let memberUID = blackHole.uid
            memberDeviceID = blackHole.id
            multiOutputID = try AudioDeviceManager.createMultiOutputDevice(
                mainUID: mainUID, memberUID: memberUID
            )
            guard let createdID = multiOutputID else {
                throw AudioDeviceError.multiOutputCreateFailed
            }
            let capturedMember = memberDeviceID
            publishIfCurrent(gen) {
                self.multiOutputID = createdID
                self.memberDeviceID = capturedMember
            }

            // STALE GATE 2: the default flip is the irreversible step - a
            // worker the watchdog already abandoned must never perform it.
            if isStale(gen) { return rollbackStaleWorker(gen: gen, step: step, defaultFlipped: defaultFlipped, multiOutputID: multiOutputID, memberDeviceID: memberDeviceID, engine: engine) }

            step = "flip default output"
            // 6. Suppression window again: flipping the default output makes
            // the mic engine's muted output unit fire a configuration change
            // that would otherwise trigger a full mic rebuild
            // mid-presentation. The window self-expires (~1.5s); it is never
            // closed early so the async change lands inside it.
            DispatchQueue.main.async { self.beginSuppression() }
            try AudioDeviceManager.setDefaultOutputDevice(id: createdID)
            defaultFlipped = true
            FileLog.log("share: [\(step)] default output flipped to multi-output")

            // 7. Published last: the UI and the render path only see the
            // share once engine, device flip, and mix bus are all live.
            // One successful enable re-arms the full heal budget.
            publishIfCurrent(gen) {
                self.isSharing = true
                self.healCount = 0
            }
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
        finishTransition(gen: gen)
    }

    /// Quiet rollback for a stale (watchdog-abandoned) enable worker that
    /// eventually returned: tear down with the LOCAL state, clear the
    /// heals-exhausted latch, clear the transition flags, and flip
    /// nothing. Runs on shareQueue; called by the stale gates (returns
    /// from performEnable). Takes the worker's OWN local engine: post-heal
    /// a newer session may own currentEngine, and this worker must never
    /// stop-and-release a NEW session's live engine.
    private func rollbackStaleWorker(gen: Int, step: String, defaultFlipped: Bool,
                                     multiOutputID: AudioDeviceID?,
                                     memberDeviceID: AudioDeviceID?,
                                     engine: AVAudioEngine?) {
        FileLog.log("share: stale worker returned (gen \(gen)); rolling back quietly (step was: \(step))")
        performTeardown(
            gen: gen, reason: "stale rollback",
            restartMic: true, cycleMic: defaultFlipped,
            engine: engine,
            multiOutputID: multiOutputID, memberDeviceID: memberDeviceID
        )
        clearWedgeIfStale(gen)
        finishTransition(gen: gen)
    }

    /// Park-safety gate for the connect: wait until the device's input ASBD
    /// is sane, stable, AND >= 2ch before a client format is applied onto
    /// it. Round-5 reframe: the park is caused by WHEN the unit is touched
    /// (mid-unstack), not WHAT is wired - so a persistent sub-healthy read
    /// is a non-quiescence signal that must terminate in refusal, never in
    /// a connect. Reads go through AudioDeviceManager.inputStreamFormat
    /// (device-object, park-safe). The first sane >=2ch read is trusted
    /// outright (probe-on-suspicion); otherwise re-read every 100ms up to
    /// formatProbeCap (4.0s), accepting two consecutive identical sane
    /// reads with the accepted read >= 2ch. At cap expiry: log and THROW
    /// code 38 (the caller performs one in-band 2s auto-retry). Returns nil
    /// only for read-FAILURES (nil/insane reads) - those fall to the
    /// round-3 ladder (helpers -> hardcode 48k/2). The distinction: a
    /// hardwired format is a format GUESS for a device we could not read at
    /// all; a persistent sub-healthy read is a device answering with
    /// non-quiescent state, which must never be connected onto. The tap's
    /// runtime mono branch stays (harmless); nothing wires mono here.
    private func probeStableInputFormat(deviceID: AudioDeviceID) throws -> (asbd: AudioStreamBasicDescription, source: String)? {
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
    /// started engine; the identity is already published on main
    /// (currentEngine) before prepare/start.
    private func startCaptureEngine(blackHoleID: AudioDeviceID) throws -> AVAudioEngine {
        FileLog.log("share: [start capture engine] creating AVAudioEngine (park-capable)")
        let engine = AVAudioEngine()
        FileLog.log("share: [start capture engine] engine created")
        // Assign BEFORE wiring: isSharing is still false, so identity-
        // matched notifications are dropped for now, and the catch's
        // teardown branch is correct from this point on. main.sync from the
        // queue is deadlock-free: main never syncs onto shareQueue.
        // The assignment only TRANSFERS the old engine out: releasing it
        // on main would run its AVAudioEngine dealloc inside this very
        // sync block - the round-6 deadlock (main parked in dealloc against
        // a wedged plugin while the worker waits on the block). The old
        // engine is dropped on the share queue, inside the bracket below.
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
        // shows pin/start failure on the quiescent device.
        //
        // Rate-settle context (hang #2): the setNominalSampleRate in step 1
        // MANUFACTURES the device reconfiguration that this pin then
        // triggers; enable #1's no-op rate set won that race, enable #2's
        // real rate set lost it and the pin's reconfiguration parked the
        // (now off-main) worker. The settle wait above shrinks the window.
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
        // (outputFormat(forBus:)); hang #3 (12:38:41) bracket-confirmed
        // this connect as the park. Formats are therefore PRE-BUILT here
        // from park-safe device-object HAL reads (inputStreamFormat /
        // nominalSampleRate / inputChannelCount, all coreaudiod
        // round-trips, never unit queries); any mismatch between the
        // wiring format and the node's real HW format is absorbed by an
        // engine-inserted sample-rate/channel converter, never by a node
        // query.
        //
        // Format ladder. PRIMARY RUNG: the stability probe - it gates the
        // client-format application below until the device's input ASBD is
        // sane and stable (park class of hang #4: applying a format onto
        // mid-unstack state, observable as a phantom 1ch ASBD read).
        // Probe-on-suspicion, never block forever waiting for 2ch. The
        // helper and hardcode rungs stay single-shot behind the probe (used
        // only when the probe returns nil, i.e. nothing sane was ever
        // read).
        var rate: Double
        var channels: Int
        var source: String
        if let probed = try probeStableInputFormat(deviceID: blackHoleID) {
            rate = probed.asbd.mSampleRate
            channels = Int(probed.asbd.mChannelsPerFrame)
            source = probed.source
        } else if let nominal = AudioDeviceManager.nominalSampleRate(deviceID: blackHoleID) {
            rate = nominal
            channels = max(2, AudioDeviceManager.inputChannelCount(deviceID: blackHoleID))
            source = "device helpers"
        } else {
            rate = 48000
            channels = 2
            source = "fallback"
        }
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
        return engine
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
        // Asymmetry note: teardown ops are reader-side wind-down
        // (removeTap/stop/release/dispose) plus device-object sets
        // (restore/destroy); they were never observed to park across three
        // rounds. The park class is WRITER-side format application
        // (startCaptureEngine only). Revisit if any teardown bracket ever
        // parks.
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
        // Identity-guarded transfer: nil only when THIS teardown's engine
        // still owns currentEngine. A post-heal newer session may already
        // own currentEngine; touching it would drop a NEW session's live
        // engine.
        var retiredEngine: AVAudioEngine? = DispatchQueue.main.sync {
            if self.currentEngine === engine {
                let old = self.currentEngine
                self.currentEngine = nil
                return old
            }
            return nil
        }
        retiredEngine = nil
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

        // 6. Clear session state (main-confined, generation-guarded).
        publishIfCurrent(gen) {
            self.multiOutputID = nil
            self.memberDeviceID = nil
            self.armedRenderRate = nil
            self.enabledAt = nil
        }

        // 7. Restart the mic engine if this teardown stopped it (on main).
        if restartMic, micWasStopped {
            DispatchQueue.main.async {
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
        // Identity-guarded transfer (see performTeardown): never nil a
        // currentEngine this worker does not own.
        var retiredEngine: AVAudioEngine? = DispatchQueue.main.sync {
            if self.currentEngine === engine {
                let old = self.currentEngine
                self.currentEngine = nil
                return old
            }
            return nil
        }
        retiredEngine = nil
        FileLog.log("share: [\(label)] partial capture engine released")
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
    /// generation is still current. The watchdog's heal clears both flags
    /// when declaring the transition stale, so the clear was redundant for
    /// a stale worker pre-heal - and post-heal it is actively harmful: an
    /// unconditional clear would unlock the UI guard mid-flight for a NEW
    /// transition running under a newer generation.
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
    /// main.sync: main never dispatches sync onto shareQueue (I5).
    private func isStale(_ gen: Int) -> Bool {
        DispatchQueue.main.sync { gen != self.transitionGeneration }
    }

    /// Clear the heals-exhausted latch if this worker is stale (the
    /// watchdog fired on it) and it managed to return and roll back: the
    /// queue demonstrably still runs, so sharing can be retried. A
    /// returned worker is proof of un-wedge, so trust resets: the heal
    /// count is zeroed alongside the latch. Safe main.sync (I5).
    private func clearWedgeIfStale(_ gen: Int) {
        DispatchQueue.main.sync {
            guard gen != self.transitionGeneration, self.healsExhausted else { return }
            self.healsExhausted = false
            self.healCount = 0
            FileLog.log("share: parked worker returned and rolled back; heals-exhausted latch cleared, heal budget reset")
        }
    }

    /// +8s main-side watchdog for the current transition: if the worker is
    /// still busy when it fires, the worker is parked in an engine/HAL
    /// call and may NEVER return. Self-heal instead of hanging the app:
    /// clear the flags so the UI unlocks, abandon the parked queue by
    /// replacing it, reset the wedged session state on main, and bump the
    /// generation so the (possibly eventually-returning) worker's flips
    /// are all treated as stale. After three failed heals, latch
    /// restart-required (healsExhausted).
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
                      gen == self.transitionGeneration else { return }
                FileLog.log("share: transition timed out; worker parked - self-healing")
                self.isSharing = false
                self.isBusy = false
                self.isTearingDown = false
                self.transitionGeneration &+= 1
                self.healCount += 1
                if self.healCount > 3 {
                    self.healsExhausted = true
                    self.userNotice = "System audio sharing keeps getting stuck. Restart the app."
                    FileLog.log("share: heal budget exhausted (\(self.healCount) heals); latching restart-required")
                    return
                }
                // Swap the abandoned queue. Its worker is parked forever;
                // the leak budget is one DispatchQueue + one parked thread
                // + at most one engine per wedge, capped at three per
                // incident. The generation suffix makes the abandoned
                // queue attributable in spindumps.
                self.shareQueue = DispatchQueue(label: "dev.zackslash.Szept.share.g\(self.transitionGeneration)",
                                                qos: .userInitiated)
                // Reset the wedged session state. SAFE per the
                // never-last-reference invariant: main's currentEngine
                // reference is never the last reference while a transition
                // is in flight (the operating worker's frame holds one),
                // so niling it here does not run a dealloc on main.
                self.currentEngine = nil
                self.multiOutputID = nil
                self.memberDeviceID = nil
                self.armedRenderRate = nil
                self.enabledAt = nil
                // A wedged enable leaves the bus armed with a dead capture.
                self.mixBus.disarm()
                self.userNotice = "System audio sharing hit a snag and reset itself. Try sharing again."
                // HAL cleanup on the FRESH queue (I5: never on main).
                let mic = self.micProcessor
                let q = self.shareQueue
                q.async { self.healCleanup(mic: mic) }
            }
        }
        if Thread.isMainThread { arm() } else { DispatchQueue.main.sync { arm() } }
    }

    /// Post-heal HAL cleanup. Runs on the FRESH share queue (never main:
    /// HAL mutations, invariant I5), so enables serialize behind this
    /// block on the serial queue.
    private func healCleanup(mic: MicProcessor?) {
        // A wedged enable may have left the multi-output as the system
        // default. Invariant I1: stop the mic engine FIRST (zero live
        // clients before destroy), then restore BEFORE destroy, mirroring
        // performTeardown's ordering.
        if AudioDeviceManager.defaultOutputDeviceUID() == Self.multiOutputUID {
            if mic?.isRunning == true {
                FileLog.log("share: [heal] stopping mic engine before multi-output destroy (park-capable)")
                mic?.stop()
            }
            Self.restorePreviousOutputFromDefaults()
        }
        // Tolerant sweep; a benign double-destroy race with the old
        // worker's own eventual rollback is fine.
        AudioDeviceManager.findAndDestroyStaleShareMultiOutput()
        // A wedged disable-side teardown must not leave the mic dead.
        DispatchQueue.main.async {
            if mic?.isRunning == false {
                self.restartMicAfterShareTeardown?()
            }
        }
        // Restamp the cooldown clock: the next enable sleeps out the
        // post-teardown window behind this block (queue confinement).
        lastTeardownCompletedAt = Date()
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
    /// destroy every match.
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
