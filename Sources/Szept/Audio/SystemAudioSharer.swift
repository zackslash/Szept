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
@Observable
final class SystemAudioSharer {

    static let multiOutputUID = AudioDeviceManager.shareMultiOutputUID
    private static let previousOutputKey = "systemAudioPreviousOutputUID"

    private(set) var isSharing = false
    var mixBus = SystemMixBus()

    /// The live capture engine, recreated FRESH per enable (AVAudioEngine
    /// restart-after-stop is flaky). Exposed so the lifecycle observer can
    /// match a configuration-change notification by object identity.
    private(set) var currentEngine: AVAudioEngine?
    private var multiOutputID: AudioDeviceID?
    /// The multi-output's BlackHole member, exposed so a mic rebuild can
    /// detect a member collision (the same BlackHole in both the private
    /// aggregate and the multi-output is the forbidden configuration).
    private(set) var memberDeviceID: AudioDeviceID?
    /// The render rate the mix bus servo was armed with (set in enable()).
    /// A rate-changing mic rebuild must re-enable the share instead of
    /// leaving the servo at a stale nominal ratio.
    private(set) var armedRenderRate: Double?
    /// When the share was enabled. Guards the config-change handler against
    /// the start-time configuration change AVAudioEngine can post as the
    /// input format finalizes; real device loss is covered by the
    /// device-list watchdog, so the grace loses nothing.
    private var enabledAt: Date?

    // MARK: - Enable

    /// Ordered enable with full rollback on any failure:
    /// 1. resolve BlackHole 16ch (required) and pin it to 48 kHz
    /// 2. arm the mix bus for the two clocks
    /// 3. save the current default output UID (stale-share cleanup first)
    /// 4. create the multi-output (speakers main, BlackHole member)
    /// 5. suppression window, flip the default output, build+start engine
    /// 6. isSharing = true (last)
    func enable(micProcessor: MicProcessor) throws {
        guard !isSharing else { return }

        // Suppression FIRST, before any default-output flip this call may
        // trigger (including the stale-cleanup restore in step 3): the
        // window is time-based, so opening it early is harmless and closing
        // it late is impossible to get wrong.
        beginSuppression()

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

        // 2. Arm the mix bus: capture at the BH16 rate we actually got
        // (read back after the best-effort 48k pin; the pin can fail), render
        // at the mic processor's output rate. Active flag is set last
        // (barrier inside).
        let inRate = AudioDeviceManager.nominalSampleRate(deviceID: blackHole.id) ?? 48000
        let renderRate = micProcessor.renderSampleRate ?? 48000
        armedRenderRate = renderRate
        mixBus.arm(inputRate: inRate, outputRate: renderRate)

        do {
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

            // 4. Multi-output: previous default (the speakers) as clock
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

            // 5. Suppression window first: flipping the default output makes
            // the mic engine's muted output unit fire a configuration change
            // that would otherwise trigger a full mic rebuild
            // mid-presentation. The window self-expires (~1.5s); it is never
            // closed early so the async change lands inside it.
            try AudioDeviceManager.setDefaultOutputDevice(id: multiOutputID)

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
            var bhID = blackHole.id
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
        } catch {
            if let engine = currentEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            currentEngine = nil
            mixBus.disarm()
            if let id = multiOutputID,
               AudioDeviceManager.defaultOutputDeviceID() == id {
                Self.restorePreviousOutputFromDefaults()
            }
            if let id = multiOutputID {
                AudioDeviceManager.destroyShareMultiOutput(id: id)
            }
            multiOutputID = nil
            throw error
        }

        // 6. Published last: the UI and the render path only see the share
        // once engine, device flip, and mix bus are all live.
        isSharing = true
        enabledAt = Date()
        FileLog.log("share: system audio sharing enabled")
    }

    // MARK: - Disable

    /// Idempotent teardown. RESTORE BEFORE DESTROY: the default output is
    /// moved back to the saved device while the multi-output still exists,
    /// so the restore can never dangle on a destroyed device.
    func disable() {
        guard isSharing || currentEngine != nil || multiOutputID != nil else { return }

        // Suppression FIRST: the default-output RESTORE flip below is the
        // mirror of the enable flip and equally fires the mic engine's
        // configuration change; unsuppressed, every share-off mid-call
        // would trigger a mic rebuild (~1-1.5s dropout).
        beginSuppression()

        // Barrier first: the render thread stops mixing immediately; the
        // ring is intentionally never freed.
        mixBus.disarm()

        if let engine = currentEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        currentEngine = nil

        // Restore only if we still own the default: the user may have
        // switched devices manually mid-share.
        if let id = multiOutputID,
           AudioDeviceManager.defaultOutputDeviceID() == id {
            Self.restorePreviousOutputFromDefaults()
        }

        if let id = multiOutputID {
            AudioDeviceManager.destroyShareMultiOutput(id: id)
        }
        multiOutputID = nil
        memberDeviceID = nil
        isSharing = false
        armedRenderRate = nil
        enabledAt = nil
        FileLog.log("share: system audio sharing disabled")
    }

    // MARK: - External change handling

    /// Engine configuration change for OUR capture engine (matched by
    /// object identity in the lifecycle observer): the BlackHole capture
    /// path broke, so tear the share down.
    func handleEngineConfigChange() {
        guard isSharing else { return }
        // Grace: AVAudioEngine can post a start-time configuration change
        // as the input format finalizes; ignore those (device-list watchdog
        // covers real loss).
        if let enabledAt, Date().timeIntervalSince(enabledAt) > 1.0 {
            FileLog.log("share: capture engine config changed, disabling")
            disable()
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
            disable()
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
            disable()
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
