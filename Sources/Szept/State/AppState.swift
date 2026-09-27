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
        switch currentMode {
        case .enhanced:   return "Voice Isolation + Szept active"
        case .standalone: return "Szept processing active"
        case .off:        return "Processing off"
        }
    }
}
