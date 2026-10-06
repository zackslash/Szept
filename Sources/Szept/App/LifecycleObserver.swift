import AppKit
import Foundation
import AVFoundation
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
final class LifecycleObserver {
    private weak var appState: AppState?

    private var wasRunningBeforeSleep = false
    private var pendingRebuild: DispatchWorkItem?
    private var observerTokens: [NSObjectProtocol] = []

    init(appState: AppState) {
        self.appState = appState
        observeSleepWake()
        observeEngineConfiguration()
        observeDeviceList()
        // Prime the snapshot so our own first aggregate creation does not
        // look like an external device-list change and trigger a spurious
        // rebuild right after the first start. The share multi-output is
        // filtered for the same reason: our own create/destroy must be
        // invisible, and a crash-leftover found at launch must not look
        // external.
        lastExternalDeviceUIDs = Set(
            ((try? AudioDeviceManager.allDevices()) ?? []).map(\.uid)
        ).subtracting([AudioDeviceManager.aggregateUID, AudioDeviceManager.shareMultiOutputUID])
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
            // Never sleep with the share multi-output as the default
            // output: the wake path would leave the meeting device wrong.
            if appState.systemSharer.isSharing {
                appState.systemSharer.disable()
                FileLog.log("sleep: system audio sharing disabled")
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
                self?.appState?.startEngineWithRetry(reason: "wake")
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
        ) { [weak self] notification in
            guard let self, let appState = self.appState else { return }
            // Object-identity check FIRST: a configuration change on the
            // share capture engine is the sharer's problem, not a mic
            // rebuild trigger.
            if let engine = notification.object as? AVAudioEngine,
               engine === appState.systemSharer.currentEngine {
                appState.systemSharer.handleEngineConfigChange()
                return
            }
            // Self-inflicted change from the sharer's default-output flip (see SystemAudioSharer.enable step 5): suppress, don't rebuild.
            if appState.systemSharer.isSuppressingRebuild {
                FileLog.log("lifecycle: rebuild suppressed (self-inflicted)")
                return
            }
            guard appState.micProcessor.isRunning else { return }
            FileLog.log("device: configuration changed")
            self.scheduleRebuild(reason: "engine configuration change")
        }
        observerTokens.append(token)
    }

    // External device UIDs as of the last device-list event, with our own
    // aggregate and share multi-output filtered out. Our own device
    // create/destroy calls fire this same listener; comparing filtered sets
    // keeps them invisible to the rebuild logic so they cannot trigger a
    // stop/start churn loop.
    private var lastExternalDeviceUIDs: Set<String> = []

    /// Coarse HAL signal that the device list changed (USB blip, coreaudiod
    /// restart). Routed through the same debounced rebuild as the engine
    /// notification so a burst of events causes one rebuild, not many.
    private func observeDeviceList() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { [weak self] _, _ in
            guard let self, let appState = self.appState else { return }
            // Filter our own devices from the current set; the stored snapshot is already filtered.
            let current = Set(((try? AudioDeviceManager.allDevices()) ?? []).map(\.uid))
            let filteredCurrent = current.subtracting([
                AudioDeviceManager.aggregateUID, AudioDeviceManager.shareMultiOutputUID
            ])
            let changed = filteredCurrent != self.lastExternalDeviceUIDs
            self.lastExternalDeviceUIDs = filteredCurrent
            // Let the sharer react to BlackHole/multi-output loss before
            // the mic rebuild guard: a dead share member must tear the
            // share down even when the mic engine itself is not running.
            appState.systemSharer.handleDeviceListChange()
            guard appState.micProcessor.isRunning, changed else { return }
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
        let wasRunning = appState.micProcessor.isRunning
        FileLog.log("device: rebuild begin (\(reason)), wasRunning=\(wasRunning)")
        guard wasRunning else { return }
        appState.micProcessor.stop()
        appState.invalidatePendingStarts()
        appState.startEngineWithRetry(reason: "rebuild (\(reason))")
    }
}
