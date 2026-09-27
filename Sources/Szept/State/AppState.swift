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
    let frontmostAppMonitor = FrontmostAppMonitor()
    var micPermissionDenied: Bool = false
    var lastError: String?

    var currentMode: SzeptMode {
        guard micProcessor.isRunning else { return .off }
        if micModeMonitor.isVoiceIsolationActive { return .enhanced }
        return .standalone
    }

    var shouldShowAppWarning: Bool {
        micProcessor.isRunning && !frontmostAppMonitor.isVoiceIsolationCompatible
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
}
