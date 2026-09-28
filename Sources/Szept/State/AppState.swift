import Observation
import Foundation

enum SzeptMode: String {
    case enhanced    // Voice Isolation + Szept stacked
    case standalone  // Szept processing only
    case off         // No processing
}

@Observable
final class AppState {
    let micProcessor = MicProcessor()
    let micModeMonitor = MicModeMonitor()
    var micPermissionDenied: Bool = false
    var lastError: String?

    var currentMode: SzeptMode {
        guard micProcessor.isRunning else { return .off }
        if micModeMonitor.isVoiceIsolationActive { return .enhanced }
        return .standalone
    }

    var statusDescription: String {
        guard micProcessor.isRunning else { return "Processing off" }
        if micProcessor.isBypassed { return "Bypass A/B active." }
        switch currentMode {
        case .enhanced:   return "Szept active with system Voice Isolation. Strongest noise reduction."
        case .standalone: return "Szept active. Turn on Voice Isolation in Control Center for stronger noise reduction."
        case .off:        return "Processing off"
        }
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
        do {
            try resolveAndAssignDevices()
            try micProcessor.start()
            let preset = UserDefaults.standard.string(forKey: "qualityPreset") ?? "aggressive"
            micProcessor.applyQualityPreset(preset)
            lastError = nil
            // Preference is never written false on failure, so a transient failure cannot disable an enabled auto-start; one attempt plus one retry, no loop.
            UserDefaults.standard.set(true, forKey: "isProcessingEnabled")
            FileLog.log("\(reason): start succeeded")
        } catch {
            FileLog.log("\(reason): start failed: \(error.localizedDescription); retrying once in 1.5s after device re-resolution")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                do {
                    try self.resolveAndAssignDevices()
                    try self.micProcessor.start()
                    let preset = UserDefaults.standard.string(forKey: "qualityPreset") ?? "aggressive"
                    self.micProcessor.applyQualityPreset(preset)
                    self.lastError = nil
                    UserDefaults.standard.set(true, forKey: "isProcessingEnabled")
                    FileLog.log("\(reason): start succeeded after retry")
                } catch {
                    let ns = error as NSError
                    FileLog.log("\(reason): start failed after retry: \(error.localizedDescription) (domain \(ns.domain), code \(ns.code))")
                    self.lastError = EngineStartError.message(for: error)
                }
            }
        }
    }
}
