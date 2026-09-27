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
        if micProcessor.isMuted { return "Muted. Mic still monitored." }
        if micProcessor.isBypassed { return "Bypass A/B active." }
        switch currentMode {
        case .enhanced:   return "Szept active with system Voice Isolation. Strongest noise reduction."
        case .standalone: return "Szept active. Turn on Voice Isolation in Control Center for stronger noise reduction."
        case .off:        return "Processing off"
        }
    }
}
