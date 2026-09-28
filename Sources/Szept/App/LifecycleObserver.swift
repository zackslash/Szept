import AppKit
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Maps a failed engine start to a user-facing message. Raw OSStatus codes
/// (for example -10875, kAudioUnitErr_CannotDoInCurrentContext, which means
/// the device is mid-reconfiguration or wedged) mean nothing to a user, so
/// OS-derived errors get a plain recovery hint. Our own NSErrors already
/// carry actionable descriptions and are passed through unchanged.
enum EngineStartError {
    static func message(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain || ns.domain == "com.apple.coreaudio.avfaudio" {
            return "Failed to start: Audio system is busy or a device changed. Try Start again in a few seconds."
        }
        return "Failed to start: \(ns.localizedDescription)"
    }
}

/// Main-thread lifecycle glue: sleep/wake, audio device changes, and the
/// shared start-with-retry path. Exists so a stale or wedged audio HAL
/// (sleep/wake, USB blips, coreaudiod restarts, BlackHole re-init) recovers
/// by tearing down and rebuilding against freshly resolved devices instead
/// of binding to dead devices forever or surfacing a raw OSStatus.
///
/// All work here is main-thread lifecycle logic; nothing touches the render
/// path. The observer lives for the lifetime of the app.
final class LifecycleObserver {
    private weak var appState: AppState?

    private var wasRunningBeforeSleep = false
    private var isRebuilding = false
    private var pendingRebuild: DispatchWorkItem?
    private var observerTokens: [NSObjectProtocol] = []

    init(appState: AppState) {
        self.appState = appState
        observeSleepWake()
        observeEngineConfiguration()
        observeDeviceList()
        FileLog.log("lifecycle: observer installed")
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            center.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Sleep / wake

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter

        let sleepToken = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let appState = self.appState else { return }
            if appState.micProcessor.isRunning {
                self.wasRunningBeforeSleep = true
                appState.micProcessor.stop()
                FileLog.log("sleep: stopping engine")
            } else {
                self.wasRunningBeforeSleep = false
            }
        }
        observerTokens.append(sleepToken)

        let wakeToken = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.wasRunningBeforeSleep else { return }
            self.wasRunningBeforeSleep = false
            guard UserDefaults.standard.bool(forKey: "isProcessingEnabled") else {
                FileLog.log("wake: auto-restart skipped, preference off")
                return
            }
            FileLog.log("wake: engine was running, restarting in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.startEngineWithRetry(reason: "wake", shouldStart: true)
            }
        }
        observerTokens.append(wakeToken)
    }

    // MARK: - Device changes

    /// The engine signals that its configuration changed (device vanished,
    /// format change, default device switch). Observed with object nil so it
    /// keeps working across engine recreations inside MicProcessor.start().
    private func observeEngineConfiguration() {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let appState = self.appState else { return }
            guard appState.micProcessor.isRunning else { return }
            FileLog.log("device: configuration changed")
            self.scheduleRebuild(reason: "engine configuration change")
        }
        observerTokens.append(token)
    }

    private var deviceListListenerInstalled = false

    /// Coarse HAL signal that the device list changed (USB blip, coreaudiod
    /// restart). Routed through the same debounced rebuild as the engine
    /// notification so a burst of events causes one rebuild, not many.
    private func observeDeviceList() {
        guard !deviceListListenerInstalled else { return }
        deviceListListenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { [weak self] _, _ in
            guard let self, let appState = self.appState else { return }
            guard appState.micProcessor.isRunning else { return }
            self.scheduleRebuild(reason: "system device list changed")
        }
    }

    /// Coalesce device events within 1 second into a single rebuild.
    private func scheduleRebuild(reason: String) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuild(reason: reason)
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func rebuild(reason: String) {
        guard let appState else { return }
        guard !isRebuilding else {
            FileLog.log("device: rebuild suppressed, one already in progress (\(reason))")
            return
        }
        isRebuilding = true
        defer { isRebuilding = false }

        let wasRunning = appState.micProcessor.isRunning
        FileLog.log("device: rebuild begin (\(reason)), wasRunning=\(wasRunning)")
        if wasRunning { appState.micProcessor.stop() }
        // Always re-resolve so a later manual Start also sees fresh devices.
        startEngineWithRetry(reason: "rebuild (\(reason))", shouldStart: wasRunning)
    }

    // MARK: - Start with retry

    /// Resolve devices, start the engine, and on failure retry once after
    /// 1.5 seconds following a fresh device re-resolve. The user only sees
    /// an error when the retry also fails, and the message is a recovery
    /// hint rather than a raw OSStatus. Every attempt and outcome is
    /// FileLog'd so post-mortems are possible.
    private func startEngineWithRetry(reason: String, shouldStart: Bool) {
        guard let appState else { return }
        guard shouldStart else {
            do {
                try appState.resolveAndAssignDevices()
                FileLog.log("\(reason): devices re-resolved (engine idle)")
            } catch {
                FileLog.log("\(reason): device re-resolution failed: \(error.localizedDescription)")
            }
            return
        }
        do {
            try appState.resolveAndAssignDevices()
            try appState.micProcessor.start()
            applyQualityPreset()
            appState.lastError = nil
            FileLog.log("\(reason): start succeeded")
        } catch {
            FileLog.log("\(reason): start failed: \(error.localizedDescription); retrying once in 1.5s after device re-resolution")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    try appState.resolveAndAssignDevices()
                    try appState.micProcessor.start()
                    self.applyQualityPreset()
                    appState.lastError = nil
                    FileLog.log("\(reason): start succeeded after retry")
                } catch {
                    let ns = error as NSError
                    FileLog.log("\(reason): start failed after retry: \(error.localizedDescription) (domain \(ns.domain), code \(ns.code))")
                    appState.lastError = EngineStartError.message(for: error)
                }
            }
        }
    }

    private func applyQualityPreset() {
        guard let appState else { return }
        let preset = UserDefaults.standard.string(forKey: "qualityPreset") ?? "aggressive"
        appState.micProcessor.applyQualityPreset(preset)
    }
}
