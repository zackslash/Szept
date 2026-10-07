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
/// multi-output (see teardownCapturedDevices): destroying a device an audio
/// unit still references can deadlock main in AVAudioEngine dealloc against
/// a wedged HAL plugin. The same invariant forbids stopping the mic engine
/// first when the share is on, while the multi-output is the default: the
/// sharer teardown (which flips the default back) must run BEFORE the mic
/// engine stops, which is why callers that stop the mic call
/// disable(restartMic: false) first.
@Observable
final class SystemAudioSharer {

    static let multiOutputUID = AudioDeviceManager.shareMultiOutputUID
    private static let previousOutputKey = "systemAudioPreviousOutputUID"

    private(set) var isSharing = false
    var mixBus = SystemMixBus()

    /// True between the start and end of a teardown, so a re-entrant
    /// enable() or disable() cannot interleave with one in progress.
    private var isTearingDown = false

    /// The live capture engine, recreated FRESH per enable (AVAudioEngine
    /// restart-after-stop is flaky). Exposed so the lifecycle observer can
    /// match a configuration-change notification by object identity.
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
    /// stopped it (cycleMic). Called only on the main thread.
    var restartMicAfterShareTeardown: (() -> Void)?

    // MARK: - Enable

    /// Ordered enable with full rollback on any failure. The capture engine
    /// is built and started BEFORE the multi-output exists, pinned to the
    /// STANDALONE BlackHole device, so the engine never has a reference to
    /// a device being created/destroyed under it:
    /// 1. resolve BlackHole 16ch (required) and pin it to 48 kHz
    /// 2. arm the mix bus for the two clocks
    /// 3. save the current default output UID (stale-share cleanup first)
    /// 4. build + start the capture engine pinned to the standalone BlackHole
    /// 5. create the multi-output (speakers main, BlackHole member)
    /// 6. suppression window, flip the default output to the multi-output
    /// 7. isSharing = true (last)
    func enable(micProcessor: MicProcessor) throws {
        guard !isSharing else { return }
        if isTearingDown {
            throw NSError(domain: "Szept", code: 35,
                          userInfo: [NSLocalizedDescriptionKey: "Sharing is shutting down, try again."])
        }

        var step = "suppression"
        do {
            // Suppression FIRST, before any default-output flip this call
            // may trigger (including the stale-cleanup restore in step 3):
            // the window is time-based, so opening it early is harmless and
            // closing it late is impossible to get wrong.
            beginSuppression()

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

            step = "arm mix bus"
            // 2. Arm the mix bus: capture at the BH16 rate we actually got
            // (read back after the best-effort 48k pin; the pin can fail),
            // render at the mic processor's output rate. Active flag is set
            // last (barrier inside).
            let inRate = AudioDeviceManager.nominalSampleRate(deviceID: blackHole.id) ?? 48000
            let renderRate = micProcessor.renderSampleRate ?? 48000
            armedRenderRate = renderRate
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
            // 250 ms settle for residual races (a rate change or device
            // notification still landing).
            self.micProcessor = micProcessor
            do {
                try startCaptureEngine(blackHoleID: blackHole.id)
            } catch {
                FileLog.log("share: [\(step)] capture engine start failed (\(error.localizedDescription)), retrying once after 250ms")
                usleep(250_000)
                try startCaptureEngine(blackHoleID: blackHole.id)
            }
            // The grace clock starts at engine start, so it also covers the
            // multi-output creation + default flip below.
            enabledAt = Date()

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
            guard let multiOutputID else {
                throw AudioDeviceError.multiOutputCreateFailed
            }

            step = "flip default output"
            // 6. Suppression window again: flipping the default output makes
            // the mic engine's muted output unit fire a configuration change
            // that would otherwise trigger a full mic rebuild
            // mid-presentation. The window self-expires (~1.5s); it is never
            // closed early so the async change lands inside it.
            beginSuppression()
            try AudioDeviceManager.setDefaultOutputDevice(id: multiOutputID)
            FileLog.log("share: [\(step)] default output flipped to multi-output")

            // 7. Published last: the UI and the render path only see the
            // share once engine, device flip, and mix bus are all live.
            isSharing = true
            FileLog.log("share: [done] system audio sharing enabled")
        } catch {
            let ns = error as NSError
            FileLog.log("share: enable FAILED at step \(step): \(ns.domain) code \(ns.code) - \(ns.localizedDescription)")
            mixBus.disarm()
            // cycleMic=false when the default flip never succeeded: the mic
            // engine never referenced the multi-output, so it must NOT be
            // stopped. If the flip happened, stop the mic and restart it.
            teardownCapturedDevices(restartMic: true, cycleMic: step == "flip default output")
            throw error
        }
    }

    /// Build, pin, wire, and start the share capture engine. Tears down any
    /// previous attempt first, so it is safe to call for the one retry.
    private func startCaptureEngine(blackHoleID: AudioDeviceID) throws {
        if let engine = currentEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            currentEngine = nil
        }

        let engine = AVAudioEngine()
        // Assign BEFORE wiring: isSharing is still false, so identity-
        // matched notifications are dropped for now, and the catch's
        // teardown branch is correct from this point on.
        currentEngine = engine
        let inputNode = engine.inputNode
        guard let inputAU = inputNode.audioUnit else {
            throw NSError(domain: "Szept", code: 33,
                          userInfo: [NSLocalizedDescriptionKey: "Capture node has no underlying audio unit"])
        }
        // Direct device open on the quiescent STANDALONE BlackHole: a
        // device nothing references yet is universally supported for a
        // pin+start. The private-mini-aggregate escape hatch (building a
        // tiny throwaway aggregate around the BlackHole to satisfy picky
        // HAL states) is deliberately NOT adopted; use it only if a retest
        // shows pin/start failure on the quiescent device.
        var bhID = blackHoleID
        let pinStatus = AudioUnitSetProperty(
            inputAU, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &bhID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard pinStatus == noErr else {
            throw AudioDeviceError.queryFailed(pinStatus)
        }

        // Never an empty graph: input -> muted mixer -> output, so the
        // engine has a complete pull chain and only the tap consumes
        // the audio.
        let format = inputNode.outputFormat(forBus: 0)
        engine.connect(inputNode, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.mainMixerNode.outputVolume = 0

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [mixBus] buffer, _ in
            guard let ptrs = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            if buffer.format.channelCount >= 2 {
                mixBus.pushStereo(ch0: ptrs[0], ch1: ptrs[1], count: frames)
            } else {
                mixBus.push(samples: ptrs[0], count: frames)
            }
        }

        engine.prepare()
        try engine.start()
        FileLog.log("share: [start capture engine] engine started on BlackHole id \(blackHoleID)")
    }

    // MARK: - Teardown

    /// The capture-side teardown, in the exact order that keeps the
    /// deadlock invariant I1 (see the class comment): every engine that can
    /// reference the multi-output (via the default output) is stopped
    /// BEFORE the multi-output is destroyed. One FileLog line per step,
    /// mirroring the enable/disable log names.
    /// - cycleMic=false is for the enable-catch, where the default flip
    ///   never succeeded and the mic engine never referenced the
    ///   multi-output, so it must not be stopped.
    private func teardownCapturedDevices(restartMic: Bool, cycleMic: Bool) {
        // 1. Stop the share capture engine.
        if let engine = currentEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        currentEngine = nil

        // 2. Stop the mic engine: it is unpinned, so its muted output unit
        // is an implicit HAL client of the multi-output (the current
        // default). Zero live clients must remain before the destroy.
        var micWasStopped = false
        if cycleMic, micProcessor?.isRunning == true {
            micProcessor?.stop()
            micWasStopped = true
            FileLog.log("share: mic engine stopped before multi-output destroy")
        }

        // 3. Restore the default only if we still own it: the user may have
        // switched devices manually mid-share. RESTORE BEFORE DESTROY, so
        // the restore can never dangle on a destroyed device.
        if let id = multiOutputID,
           AudioDeviceManager.defaultOutputDeviceID() == id {
            Self.restorePreviousOutputFromDefaults()
        }

        // 4. Re-arm suppression around the restore flip, mirroring the
        // enable flip: it equally fires the mic engine's configuration
        // change when the mic engine is still running (cycleMic=false).
        beginSuppression()

        // 5. Destroy the multi-output (now unreferenced).
        if let id = multiOutputID {
            AudioDeviceManager.destroyShareMultiOutput(id: id)
        }

        // 6. Clear session state.
        multiOutputID = nil
        memberDeviceID = nil
        armedRenderRate = nil
        enabledAt = nil

        // 7. Restart the mic engine if this teardown stopped it.
        if restartMic, micWasStopped {
            restartMicAfterShareTeardown?()
        }
    }

    /// Idempotent teardown. RESTORE BEFORE DESTROY: the default output is
    /// moved back to the saved device while the multi-output still exists,
    /// so the restore can never dangle on a destroyed device. The mic
    /// engine is stopped (and optionally restarted via the injected
    /// closure) INSIDE the teardown, in the safe order.
    func disable(restartMic: Bool = true) {
        guard isSharing, !isTearingDown else { return }

        isTearingDown = true
        defer { isTearingDown = false }

        // Published FIRST so UI and render path stop consulting the share
        // before anything is torn down.
        isSharing = false

        // Barrier first: the render thread stops mixing immediately; the
        // ring is intentionally never freed.
        mixBus.disarm()
        FileLog.log("share: system audio sharing disabled")

        teardownCapturedDevices(restartMic: restartMic, cycleMic: true)
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
            disable(restartMic: true)
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
            disable(restartMic: true)
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
            disable(restartMic: true)
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

    /// Owns the timestamp the lifecycle observer checks. Main thread only.
    private var suppressionUntil = Date.distantPast
    private static let suppressionInterval: TimeInterval = 1.5

    var isSuppressingRebuild: Bool { Date() < suppressionUntil }

    /// Open the window around the default-output flip + capture engine start.
    private func beginSuppression() {
        suppressionUntil = Date().addingTimeInterval(Self.suppressionInterval)
    }
}
