import Foundation

/// Every user-facing action the control layer can fire (hotkeys, `szept://`
/// URLs). Pure value type with no AppKit or Carbon dependencies, so it can be
/// constructed from any entry point.
enum AppAction: CaseIterable {
    case toggleEngine
    case cycleClarity
    case strengthUp
    case strengthDown
    case bypassOn
    case bypassOff
    case bypassToggle

    /// Parse a `szept://` URL into an action. In custom-scheme URLs the verb
    /// is the host; an optional sub-verb is the first path component, e.g.
    /// `szept://strength/down`. Returns nil for unknown schemes or verbs so
    /// callers can silently ignore unrecognized links.
    static func from(url: URL) -> AppAction? {
        guard url.scheme?.lowercased() == "szept" else { return nil }
        let host = url.host?.lowercased() ?? ""
        let sub = url.pathComponents.dropFirst().first?.lowercased() ?? ""
        switch (host, sub) {
        case ("toggle", _):        return .toggleEngine
        case ("clarity", _):       return .cycleClarity
        case ("strength", "down"): return .strengthDown
        case ("strength", _):      return .strengthUp
        case ("bypass", "on"):     return .bypassOn
        case ("bypass", "off"):    return .bypassOff
        case ("bypass", _):        return .bypassToggle
        default:                   return nil
        }
    }

    /// Perform the action on the shared app state. Main thread only.
    func perform(on appState: AppState) {
        switch self {
        case .toggleEngine:
            toggleEngine(on: appState)
        case .cycleClarity:
            cycleClarity(on: appState)
        case .strengthUp:
            shiftStrength(on: appState, up: true)
        case .strengthDown:
            shiftStrength(on: appState, up: false)
        case .bypassOn:
            appState.micProcessor.setBypassed(true)
        case .bypassOff:
            appState.micProcessor.setBypassed(false)
        case .bypassToggle:
            appState.micProcessor.setBypassed(!appState.micProcessor.isBypassed)
        }
    }

    // MARK: - Actions

    private func toggleEngine(on appState: AppState) {
        let defaults = UserDefaults.standard
        if appState.micProcessor.isRunning {
            appState.micProcessor.stop()
            appState.invalidatePendingStarts()
            appState.lastError = nil
            defaults.set(false, forKey: "isProcessingEnabled")
        } else {
            appState.startEngineWithRetry(reason: "engine")
        }
    }

    private func cycleClarity(on appState: AppState) {
        let order = ClarityLevel.allCases   // off, low, medium, high
        let current = storedClarity
        guard let idx = order.firstIndex(of: current) else { return }
        let next = order[(idx + 1) % order.count]
        UserDefaults.standard.set(next.rawValue, forKey: "clarityLevel")
        appState.micProcessor.setClarity(next)
    }

    private func shiftStrength(on appState: AppState, up: Bool) {
        let presets = ["light", "balanced", "aggressive"]
        let current = UserDefaults.standard.string(forKey: "qualityPreset") ?? "aggressive"
        let idx = presets.firstIndex(of: current) ?? (presets.count - 1)
        let next = up ? min(presets.count - 1, idx + 1) : max(0, idx - 1)
        let preset = presets[next]
        UserDefaults.standard.set(preset, forKey: "qualityPreset")
        appState.micProcessor.applyQualityPreset(preset)
    }

    private var storedClarity: ClarityLevel {
        let raw = UserDefaults.standard.string(forKey: "clarityLevel") ?? "off"
        return ClarityLevel(rawValue: raw) ?? .off
    }
}
