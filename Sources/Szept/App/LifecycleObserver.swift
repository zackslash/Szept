import AppKit
import Foundation
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
        observeDeviceList()
        // Prime the snapshot (raw device IDs, with our own created devices
        // excluded by ID: the mic aggregate and the share multi-output) so
        // our own first device creations do not look like an external
        // device-list change and trigger a spurious rebuild. Our own
        // create/destroy must be invisible, and a crash-leftover found at
        // launch (destroyed by the stale cleanup just before this) must not
        // look external.
        lastStableDeviceIDs = primeSnapshot()
        FileLog.log("lifecycle: observer installed")
    }

    /// External device IDs as of the last accepted device-list state, with
    /// our own created devices (mic aggregate, share multi-output) excluded
    /// by ID. Diffing raw IDs (no per-device property reads) keeps our own
    /// create/destroy calls invisible to the rebuild logic so they cannot
    /// trigger a stop/start churn loop.
    private var lastStableDeviceIDs: Set<AudioDeviceID> = []
    /// The last observed (but not yet confirmed) difference from the stable
    /// set; a second identical observation confirms a real change.
    private var pendingDeviceIDs: Set<AudioDeviceID>?

    /// Current raw device-ID set minus our own created devices. Returns nil
    /// when the enumeration fails: a failed enumeration must never be
    /// mistaken for an empty or changed device list.
    private func filteredDeviceIDs(appState: AppState) -> Set<AudioDeviceID>? {
        guard let ids = try? AudioDeviceManager.allDeviceIDs() else { return nil }
        var set = Set(ids)
        if let aggregateID = appState.micProcessor.aggregateDeviceID {
            set.remove(aggregateID)
        }
        if let multiOutputID = appState.systemSharer.multiOutputID {
            set.remove(multiOutputID)
        }
        return set
    }

    /// One-time init snapshot. Belt and suspenders: also excludes any
    /// device still carrying one of our UIDs (post-cleanup there are none,
    /// but a failed destroy at launch must not look external).
    private func primeSnapshot() -> Set<AudioDeviceID> {
        guard let appState else { return [] }
        guard let ids = try? AudioDeviceManager.allDeviceIDs() else {
            FileLog.log("device: enumeration failed, ignoring")
            return []
        }
        let ownIDs: Set<AudioDeviceID> = Set([
            appState.micProcessor.aggregateDeviceID,
            appState.systemSharer.multiOutputID
        ].compactMap { $0 })
        let uidExcluded: Set<AudioDeviceID> = Set(
            ((try? AudioDeviceManager.allDevices()) ?? [])
                .filter { $0.uid == AudioDeviceManager.aggregateUID
                    || $0.uid == AudioDeviceManager.shareMultiOutputUID }
                .map(\.id)
        )
        return Set(ids).subtracting(ownIDs).subtracting(uidExcluded)
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
            // Share teardown BEFORE the mic stop: the teardown stops the
            // mic engine itself (invariant I1), in the safe order.
            // Never sleep with the share multi-output as the default
            // output: the wake path would leave the meeting device wrong.
            // restartMic=false: the engine goes down for sleep anyway.
            // Accepted risk: the disable is async now (invariant I5), so
            // the teardown may straddle the actual sleep; a multi-output
            // leftover across sleep is owned by launch-time
            // cleanupStaleDevices and the next enable's stale cleanup.
            if appState.systemSharer.isSharing {
                Task { await appState.systemSharer.disable(restartMic: false) }
                FileLog.log("sleep: system audio sharing disabled")
            }
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
                self?.appState?.startEngineWithRetry(reason: "wake")
            }
        }
        observerTokens.append(wakeToken)
    }

    // MARK: - Device changes

    // Sole rebuild trigger: the device-list watchdog. There is no
    // engine-configuration observer - the app contains ZERO AVAudioEngines
    // (invariant I6), so .AVAudioEngineConfigurationChange can never fire,
    // and default-output changes no longer affect the mic path at all
    // (every unit is pinned to its own target). Input-device loss is
    // covered by the device-list rebuild below. Known gap: a mid-session
    // input FORMAT change (the interface renegotiated under us) degrades
    // until restart - the capture context is shaped to the start-time
    // probe, and the callback fail-opens to silence on a shape mismatch.
    // A kAudioUnitProperty_StreamFormat listener is parked as a follow-up.

    /// Coarse HAL signal that the device list changed (USB blip, coreaudiod
    /// restart). Routed through the debounced rebuild so a burst of events
    /// causes one rebuild, not many.
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
            // A failed enumeration must not look like a change: keep the
            // snapshot, do not rebuild.
            guard let current = self.filteredDeviceIDs(appState: appState) else {
                FileLog.log("device: enumeration failed, ignoring")
                return
            }
            // Let the sharer react to BlackHole/multi-output loss before
            // the mic rebuild guard: a dead share member must tear the
            // share down even when the mic engine itself is not running.
            appState.systemSharer.handleDeviceListChange()
            guard appState.micProcessor.isRunning else { return }
            if current != self.lastStableDeviceIDs {
                // Snapshot NOT adopted here: the debounced re-check decides
                // whether the difference is real.
                self.scheduleRebuild(reason: "system device list changed")
            }
        }
    }

    /// Coalesce device events within 1 second into a single re-check.
    private func scheduleRebuild(reason: String) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recheckDevices(reason: reason)
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Re-enumerate and compare against the last stable ID set. A transient
    /// difference (gone by now) is skipped; a real difference must be
    /// observed twice (pendingIDs confirmed) before a rebuild runs.
    private func recheckDevices(reason: String) {
        guard let appState else { return }
        guard let current = filteredDeviceIDs(appState: appState) else {
            FileLog.log("device: enumeration failed, ignoring")
            return
        }
        if current == lastStableDeviceIDs {
            FileLog.log("device: rebuild skipped, transient difference")
            pendingDeviceIDs = nil
            return
        }
        if pendingDeviceIDs == current {
            // Confirmed twice: accept the change, rebuild, adopt.
            logDeviceDelta(from: lastStableDeviceIDs, to: current)
            rebuild(reason: reason)
            lastStableDeviceIDs = current
            pendingDeviceIDs = nil
        } else {
            FileLog.log("device: list difference observed once, re-checking")
            pendingDeviceIDs = current
            scheduleRebuild(reason: reason)
        }
    }

    /// Best-effort added/removed logging with device names. Never throws.
    private func logDeviceDelta(from old: Set<AudioDeviceID>, to new: Set<AudioDeviceID>) {
        func describe(_ ids: Set<AudioDeviceID>) -> String {
            ids.sorted().map { id in
                let name = AudioDeviceManager.deviceName(deviceID: id) ?? "?"
                return "\(id)(\(name))"
            }.joined(separator: ", ")
        }
        FileLog.log("device: list changed +[\(describe(new.subtracting(old)))] -[\(describe(old.subtracting(new)))]")
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
