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
    }

    // MARK: - System audio sharing

    func toggleSystemAudio() {
        setSystemAudio(!systemSharer.isSharing)
    }

    /// Enable/disable system-audio sharing, surfacing any failure to the
    /// error banner. Main thread only. lastError is cleared only when an
    /// actual transition occurred.
    func setSystemAudio(_ on: Bool) {
        if on {
            // Sharing requires the mic pipeline to be up: the mix bus is
            // consumed by its render path.
            guard micProcessor.isRunning else {
                lastError = "Start processing before sharing system audio."
                return
            }
            do {
                try systemSharer.enable(micProcessor: micProcessor)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            guard systemSharer.isSharing else { return }
            systemSharer.disable()
            lastError = nil
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
                    // engine-off path. The user re-toggles share after
                    // recovery, same as post-sleep.
                    if self.systemSharer.isSharing {
                        self.systemSharer.disable()
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
            systemSharer.disable()
            do { try systemSharer.enable(micProcessor: micProcessor) }
            catch { lastError = error.localizedDescription }
        }
        // Preference is never written false on failure: a transient
        // failure must not disable an enabled auto-start. One attempt
        // plus one retry; no loop to guard against.
        UserDefaults.standard.set(true, forKey: "isProcessingEnabled")
        FileLog.log("\(reason): \(tag)")
    }
}
