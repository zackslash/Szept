import Observation
import Foundation

enum SzeptMode: String {
    case enhanced    // Voice Isolation + Szept stacked
    case standalone  // Szept processing only
    case off         // No processing
}

@Observable
final class AppState {
    let systemSharer = SystemAudioSharer()
    let micProcessor: MicProcessor
    let micModeMonitor = MicModeMonitor()
    var micPermissionDenied: Bool = false
    var lastError: String?

    init() {
        micProcessor = MicProcessor(systemMixBus: systemSharer.mixBus)
        // A share teardown that had to stop the mic engine (invariant I1:
        // stop clients before destroying the multi-output) asks us to bring
        // it back through the same retrying start path as everything else.
        // The sharer invokes this on main; the dispatch keeps that
        // guaranteed even if a future call site hops.
        systemSharer.restartMicAfterShareTeardown = { [weak self] in
            DispatchQueue.main.async {
                self?.startEngineWithRetry(reason: "share teardown")
            }
        }
    }

    // MARK: - System audio sharing

    func toggleSystemAudio() {
        setSystemAudio(!systemSharer.isSharing)
    }

    /// Enable/disable system-audio sharing, surfacing any failure to the
    /// error banner. Main thread only; the sharer's engine/HAL work runs on
    /// its worker queue (invariant I5), so this spawns Tasks. lastError is
    /// cleared only when an actual transition occurred.
    func setSystemAudio(_ on: Bool) {
        // Surface a watchdog notice from a previous stuck transition.
        if let notice = systemSharer.userNotice {
            lastError = notice
            systemSharer.userNotice = nil
        }
        if on {
            // Sharing requires the mic pipeline to be up: the mix bus is
            // consumed by its render path.
            guard micProcessor.isRunning else {
                lastError = "Start processing before sharing system audio."
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.systemSharer.enable(micProcessor: self.micProcessor)
                    await MainActor.run { self.lastError = nil }
                } catch {
                    await MainActor.run { self.lastError = error.localizedDescription }
                }
            }
        } else {
            guard systemSharer.isSharing else { return }
            Task { [weak self] in
                await self?.systemSharer.disable(restartMic: true)
                await MainActor.run { self?.lastError = nil }
            }
        }
    }

    // Bumped on every start attempt and every stop (user or rebuild); a
    // pending retry carries the generation it was scheduled under and
    // aborts if it no longer matches.
    private var startGeneration = 0

    /// Invalidates any pending start retry (call from every user-stop path).
    func invalidatePendingStarts() {
        startGeneration += 1
    }

    var currentMode: SzeptMode {
        guard micProcessor.isRunning else { return .off }
        if micModeMonitor.isVoiceIsolationActive { return .enhanced }
        return .standalone
    }

    var statusDescription: String {
        guard micProcessor.isRunning else { return "Processing off" }
        if micProcessor.isBypassed { return "Bypass A/B active." }
        // The muted line comes first: it changes what the call hears.
        let base = micModeMonitor.isVoiceIsolationActive
            ? "Szept active with system Voice Isolation. Strongest noise reduction."
            : "Szept active. Turn on Voice Isolation in Control Center for stronger noise reduction."
        return micProcessor.voiceMuted ? "Mic muted\n" + base : base
    }

    // MARK: - Device resolution

    /// Resolves the configured input/output devices and assigns them to the
    /// processor. Throws (without starting the engine) if no usable output
    /// device exists — audio is never routed to the system default output,
    /// which would blast the processed mic from the speakers.
    ///
    /// Lives on AppState so hotkey/URL actions can re-resolve stale devices
    /// and retry a failed start (see AppAction.toggleEngine).
    func resolveAndAssignDevices() throws {
        let inputUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? ""
        if !inputUID.isEmpty {
            if let input = try AudioDeviceManager.findDevice(uid: inputUID) {
                micProcessor.inputDeviceID = input.id
            } else {
                throw NSError(domain: "Szept", code: 20,
                              userInfo: [NSLocalizedDescriptionKey: "Selected input device not found. Reconnect it or pick another microphone in Settings."])
            }
        } else {
            micProcessor.inputDeviceID = nil
        }

        let outputUID = UserDefaults.standard.string(forKey: "outputDeviceUID") ?? ""
        if !outputUID.isEmpty {
            if let output = try AudioDeviceManager.findDevice(uid: outputUID) {
                micProcessor.outputDeviceID = output.id
            } else {
                throw NSError(domain: "Szept", code: 21,
                              userInfo: [NSLocalizedDescriptionKey: "Selected output device not found. Reconnect it or pick another device in Settings."])
            }
        } else if let blackHole = try AudioDeviceManager.firstBlackHole() {
            micProcessor.outputDeviceID = blackHole.id
        } else {
            throw NSError(domain: "Szept", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "No output device found. Install BlackHole (existential.audio/blackhole) or pick a device in Settings."])
        }
    }

    // MARK: - Start with retry

    /// Resolve devices, start the engine, and on failure retry once after
    /// 1.5 seconds following a fresh device re-resolve. The user only sees
    /// an error when the retry also fails, and the message is a recovery
    /// hint rather than a raw OSStatus. Every attempt and outcome is
    /// FileLog'd so post-mortems are possible.
    func startEngineWithRetry(reason: String) {
        startGeneration += 1
        let generation = startGeneration

        do {
            try attempt("start succeeded", reason: reason)
        } catch {
            FileLog.log("\(reason): start failed: \(error.localizedDescription); retrying once in 1.5s after device re-resolution")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                guard generation == self.startGeneration else { return }
                do {
                    try self.attempt("start succeeded after retry", reason: reason)
                } catch {
                    let ns = error as NSError
                    FileLog.log("\(reason): start failed after retry: \(error.localizedDescription) (domain \(ns.domain), code \(ns.code))")
                    self.lastError = EngineStartError.message(for: error)
                    // Share cannot outlive a dead engine: same rule as the
                    // engine-off path. restartMic=false: the engine just
                    // failed for its own reasons; no restart loop. The user
                    // re-toggles share after recovery, same as post-sleep.
                    if self.systemSharer.isSharing {
                        Task { await self.systemSharer.disable(restartMic: false) }
                    }
                }
            }
        }
    }

    /// One start attempt: resolve, start, apply preset, clear error,
    /// record success. Throws on failure; callers own retry policy.
    private func attempt(_ tag: String, reason: String) throws {
        try resolveAndAssignDevices()
        try micProcessor.start()
        let preset = UserDefaults.standard.string(forKey: "qualityPreset") ?? "aggressive"
        micProcessor.applyQualityPreset(preset)
        lastError = nil
        // A rate change since arm() leaves the servo on a stale nominal
        // ratio: re-enable - never a bare re-arm (resetting ring indices
        // under a live capture tap corrupts the ring). A member collision
        // (the rebuilt private aggregate around the same BlackHole the
        // multi-output contains) is the other forbidden state, so it forces
        // a re-enable too. The sharer's create/destroy is filtered from the
        // observer's snapshots, so the pair cannot trigger a rebuild.
        if systemSharer.isSharing,
           (micProcessor.renderSampleRate != systemSharer.armedRenderRate
               && micProcessor.renderSampleRate != nil)
               || systemSharer.memberDeviceID == micProcessor.outputDeviceID {
            // Async re-enable (invariant I5): the sharer's engine/HAL work
            // runs on its worker queue, so the disable+enable pair is
            // dispatched as a Task; attempt() no longer blocks on it. The
            // sharer's own isBusy/transition-generation guard keeps the
            // pair serialized against user toggles.
            FileLog.log("share: re-enable dispatched post-restart")
            Task { [weak self] in
                guard let self else { return }
                await self.systemSharer.disable(restartMic: false)
                do {
                    try await self.systemSharer.enable(micProcessor: self.micProcessor)
                    await MainActor.run { self.lastError = nil }
                } catch {
                    await MainActor.run { self.lastError = error.localizedDescription }
                }
            }
        }
        // Preference is never written false on failure: a transient
        // failure must not disable an enabled auto-start. One attempt
        // plus one retry; no loop to guard against.
        UserDefaults.standard.set(true, forKey: "isProcessingEnabled")
        FileLog.log("\(reason): \(tag)")
    }
}
