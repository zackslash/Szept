import Foundation

/// Every user-facing action the control layer can fire (hotkeys, `szept://`
/// URLs). Pure value type with no AppKit or Carbon dependencies, so it can be
/// constructed from any entry point.
enum AppAction {
    case toggleEngine
    case cycleClarity
    case strengthUp
    case strengthDown
    case bypassOn
    case bypassOff
    case bypassToggle
    case shareToggle
    case shareOn
    case shareOff
    case voiceMuteToggle
    case voiceMuteOn
    case voiceMuteOff
    case outputDump

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
        case ("systemaudio", "on"):  return .shareOn
        case ("systemaudio", "off"): return .shareOff
        case ("systemaudio", _):     return .shareToggle
        // Voice-only mute. Deliberately NOT "mute": that verb was removed
        // for double-mute risk and stays unrecognized.
        case ("voicemute", "on"):  return .voiceMuteOn
        case ("voicemute", "off"): return .voiceMuteOff
        case ("voicemute", _):     return .voiceMuteToggle
        // Diagnostic: dump exactly what the voice pipeline delivers.
        case ("dump", _):          return .outputDump
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
        case .shareToggle:
            appState.toggleSystemAudio()
        case .shareOn:
            appState.setSystemAudio(true)
        case .shareOff:
            appState.setSystemAudio(false)
        case .voiceMuteToggle:
            appState.micProcessor.setVoiceMuted(!appState.micProcessor.voiceMuted)
        case .voiceMuteOn:
            appState.micProcessor.setVoiceMuted(true)
        case .voiceMuteOff:
            appState.micProcessor.setVoiceMuted(false)
        case .outputDump:
            appState.micProcessor.armOutputDump()
        }
    }

    // MARK: - Actions

    private func toggleEngine(on appState: AppState) {
        // Belt-and-braces gate for the hotkey/URL paths (the MenuView
        // button is already disabled): a share transition in flight stops
        // the mic pipeline itself (I1), so a concurrent engine toggle would
        // interleave with it.
        guard !appState.systemSharer.isBusy else {
            FileLog.log("engine: toggle ignored, share transition in progress")
            return
        }
        let defaults = UserDefaults.standard
        if appState.micProcessor.isRunning {
            // Sharer teardown BEFORE the mic stop: it stops the mic pipeline
            // itself (idempotent) in the safe order, before the
            // multi-output is destroyed (invariant I1). Async: invariant I5.
            Task { await appState.systemSharer.disable(restartMic: false) }
            appState.micProcessor.stop()
            // Szept off = everything off: the share mixes into the mic
            // render path, so it cannot outlive the pipeline.
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
