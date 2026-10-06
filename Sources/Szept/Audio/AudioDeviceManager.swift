import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int
}

enum AudioDeviceError: LocalizedError {
    case queryFailed(OSStatus)
    case aggregateCreateFailed
    case multiOutputCreateFailed

    var errorDescription: String? {
        switch self {
        case .queryFailed(let status):
            return "Audio device query failed (code \(status))"
        case .aggregateCreateFailed:
            return "Could not create the Szept aggregate device (HAL returned no device)"
        case .multiOutputCreateFailed:
            return "Could not create the Szept Share multi-output device (HAL returned no device)"
        }
    }
}

final class AudioDeviceManager {

    // MARK: - Queries

    static func allDevices() throws -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr else { throw AudioDeviceError.queryFailed(status) }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        let buffer = UnsafeMutableBufferPointer<AudioDeviceID>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard let deviceIDPointer = buffer.baseAddress else { return [] }

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, deviceIDPointer
        )
        guard status == noErr else { throw AudioDeviceError.queryFailed(status) }

        var deviceIDs: [AudioDeviceID] = []
        deviceIDs.reserveCapacity(count)
        for i in 0..<(Int(size) / MemoryLayout<AudioDeviceID>.size) {
            deviceIDs.append(buffer[i])
        }

        var devices: [AudioDeviceInfo] = []
        devices.reserveCapacity(deviceIDs.count)
        for deviceID in deviceIDs {
            // A dead device (unreadable properties) is skipped, not fatal:
            // one poisoned entry must not break the whole enumeration.
            if let info = try? deviceInfo(for: deviceID) {
                devices.append(info)
            }
        }
        return devices
    }

    static func inputDevices() throws -> [AudioDeviceInfo] {
        // Our own aggregates and the share multi-output never belong in a
        // user-facing picker.
        try allDevices().filter {
            $0.inputChannelCount > 0
                && $0.uid != aggregateUID
                && $0.uid != shareMultiOutputUID
        }
    }

    static func outputDevices() throws -> [AudioDeviceInfo] {
        try allDevices().filter {
            $0.outputChannelCount > 0
                && $0.uid != aggregateUID
                && $0.uid != shareMultiOutputUID
        }
    }

    static func findDevice(uid: String) throws -> AudioDeviceInfo? {
        try allDevices().first { $0.uid == uid }
    }

    static func firstBlackHole() throws -> AudioDeviceInfo? {
        let matches = try allDevices().filter {
            $0.name.localizedCaseInsensitiveContains("BlackHole")
        }
        // Prefer devices that expose outputs (loopback targets)
        return matches.first { $0.outputChannelCount > 0 } ?? matches.first
    }

    // MARK: - Per-device properties

    private static func deviceInfo(for deviceID: AudioDeviceID) throws -> AudioDeviceInfo? {
        let name = try stringProperty(selector: kAudioObjectPropertyName, deviceID: deviceID)
            ?? "Unknown device"
        let uid = try stringProperty(selector: kAudioDevicePropertyDeviceUID, deviceID: deviceID) ?? ""

        let inputChannels = try channelCount(
            deviceID: deviceID, scope: kAudioObjectPropertyScopeInput
        )
        let outputChannels = try channelCount(
            deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput
        )

        return AudioDeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels
        )
    }

    private static func stringProperty(
        selector: AudioObjectPropertySelector, deviceID: AudioDeviceID
    ) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { throw AudioDeviceError.queryFailed(status) }
        guard size > 0 else { return nil }

        var value: Unmanaged<CFString>? = nil
        status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw AudioDeviceError.queryFailed(status) }
        guard let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }

    private static func channelCount(
        deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { throw AudioDeviceError.queryFailed(status) }
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }

        // AudioBufferList is variable length: allocate the full reported byte
        // size, not just the struct, or multi-buffer devices overflow the heap.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        memset(raw, 0, Int(size))

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        guard status == noErr else { throw AudioDeviceError.queryFailed(status) }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buffer in list {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }

    // MARK: - Aggregate device (drift-free bridge)

    /// Stable UID for our private aggregate device so a leftover from a
    /// crashed session can always be found and destroyed before a new one
    /// is created, keeping state deterministic.
    static let aggregateUID = "dev.zackslash.Szept.Aggregate"
    private static let aggregateName = "Szept Bridge"

    /// The kAudioDevicePropertyDeviceUID of a device, or nil if it cannot
    /// be read. Tolerant by design: aggregate creation is best effort.
    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        (try? stringProperty(selector: kAudioDevicePropertyDeviceUID, deviceID: deviceID)) ?? nil
    }

    static func outputChannelCount(deviceID: AudioDeviceID) -> Int {
        (try? channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)) ?? 0
    }

    static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &deviceID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, pointer
            )
        }
        guard status == noErr, deviceID != 0 else {
            throw AudioDeviceError.queryFailed(status)
        }
        return deviceID
    }

    /// Create the private aggregate bridging input (clock master) and
    /// loopback output onto one clock, destroying any stale aggregate first.
    static func createAggregateDevice(inputDeviceUID: String, outputDeviceUID: String) throws -> AudioDeviceID {
        findAndDestroyStaleAggregate()

        let subDevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey as String: inputDeviceUID],
            // Drift compensation on the BlackHole leg: it slaves to the
            // clock master (the input device).
            [kAudioSubDeviceUIDKey as String: outputDeviceUID,
             kAudioSubDeviceDriftCompensationKey as String: 1]
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: aggregateName,
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            // Clock master: the input device. Everything else on the
            // aggregate resamples/slaves to it.
            kAudioAggregateDeviceMainSubDeviceKey as String: inputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            // Hidden from other apps; only our process can open it.
            kAudioAggregateDeviceIsPrivateKey as String: true
        ]
        let cfDescription = description as CFDictionary

        var newID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(cfDescription, &newID)
        guard status == noErr, newID != kAudioObjectUnknown else {
            throw AudioDeviceError.aggregateCreateFailed
        }
        FileLog.log("aggregate: created id \(newID) (input \(inputDeviceUID) as clock master, output \(outputDeviceUID) as member)")
        return newID
    }

    /// Destroy an aggregate we created. Tolerant: already-gone or a wedged
    /// HAL is logged and ignored, never thrown.
    static func destroyAggregateDevice(id: AudioDeviceID) {
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status == noErr {
            FileLog.log("aggregate: destroyed device id \(id)")
        } else {
            FileLog.log("aggregate: destroy returned \(status) for id \(id) (ignored)")
        }
    }

    /// Destroy any aggregate carrying our stable UID, for example one left
    /// behind by a crash.
    private static func findAndDestroyStaleAggregate() {
        guard let devices = try? allDevices() else { return }
        for device in devices where device.uid == aggregateUID {
            FileLog.log("aggregate: destroying stale device id \(device.id)")
            destroyAggregateDevice(id: device.id)
        }
    }

    // MARK: - Share multi-output device (system audio sharing)

    /// Stable UID of the visible multi-output device used while sharing
    /// system audio. Visible (NOT private) on purpose: it must be selectable
    /// as another process's default output. Filtered out of pickers and the
    /// lifecycle observer's device snapshots everywhere aggregateUID is.
    static let shareMultiOutputUID = "dev.zackslash.Szept.Share"
    private static let shareMultiOutputName = "Szept Share"

    /// Create the visible multi-output device used for sharing. The main
    /// sub-device (the speakers) is the clock master and defines the
    /// app-facing format; the member (BlackHole) runs with drift
    /// compensation. IsStacked is what makes this a MULTI-OUTPUT device
    /// (every member receives the same stream) rather than a channel-
    /// concatenating aggregate. The device must not be private: it has to
    /// be visible so the system (another process context) can adopt it as
    /// the default output.
    ///
    /// Retry-once with the main key omitted: some HAL builds reject a main
    /// sub-device that is already the system default; without an explicit
    /// master the first list entry becomes the clock master anyway.
    static func createMultiOutputDevice(mainUID: String, memberUID: String) throws -> AudioDeviceID {
        findAndDestroyStaleShareMultiOutput()

        func buildDescription(withMain: Bool) -> [String: Any] {
            let subDevices: [[String: Any]] = [
                [kAudioSubDeviceUIDKey as String: mainUID],
                [kAudioSubDeviceUIDKey as String: memberUID,
                 kAudioSubDeviceDriftCompensationKey as String: 1]
            ]
            var description: [String: Any] = [
                kAudioAggregateDeviceNameKey as String: shareMultiOutputName,
                kAudioAggregateDeviceUIDKey as String: shareMultiOutputUID,
                kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
                // THIS makes it a multi-output: duplicate the stream to
                // every member instead of concatenating channels.
                kAudioAggregateDeviceIsStackedKey as String: true,
                // Must be visible to become another process's default output.
                kAudioAggregateDeviceIsPrivateKey as String: false
            ]
            if withMain {
                description[kAudioAggregateDeviceMainSubDeviceKey as String] = mainUID
            }
            return description
        }

        var newID: AudioDeviceID = 0
        var status = AudioHardwareCreateAggregateDevice(buildDescription(withMain: true) as CFDictionary, &newID)
        if status != noErr || newID == kAudioObjectUnknown {
            FileLog.log("share: multi-output create with main failed (\(status)), retrying without explicit master")
            newID = 0
            status = AudioHardwareCreateAggregateDevice(buildDescription(withMain: false) as CFDictionary, &newID)
        }
        guard status == noErr, newID != kAudioObjectUnknown else {
            throw AudioDeviceError.multiOutputCreateFailed
        }
        FileLog.log("share: created multi-output id \(newID) (main \(mainUID), member \(memberUID))")
        return newID
    }

    /// Destroy a share multi-output device we created. Tolerant like its
    /// aggregate twin: failures are logged and ignored.
    static func destroyShareMultiOutput(id: AudioDeviceID) {
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status == noErr {
            FileLog.log("share: destroyed multi-output id \(id)")
        } else {
            FileLog.log("share: destroy returned \(status) for id \(id) (ignored)")
        }
    }

    /// Destroy any multi-output carrying the share UID (crash leftover).
    static func findAndDestroyStaleShareMultiOutput() {
        guard let devices = try? allDevices() else { return }
        for device in devices where device.uid == shareMultiOutputUID {
            FileLog.log("share: destroying stale multi-output id \(device.id)")
            destroyShareMultiOutput(id: device.id)
        }
    }

    // MARK: - Default output device

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &deviceID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, pointer
            )
        }
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return deviceUID(for: id)
    }

    /// INTENTIONALLY does not touch kAudioHardwarePropertyDefaultSystemOutputDevice:
    /// alert/notification sounds stay on the old device, so notification
    /// dings do not feed the meeting through BlackHole during a share.
    static func setDefaultOutputDevice(id: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &deviceID) { pointer in
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, pointer
            )
        }
        guard status == noErr else {
            throw AudioDeviceError.queryFailed(status)
        }
    }

    /// Read back a device's current nominal sample rate, mirroring
    /// MicProcessor's private deviceSampleRate pattern. Used by the share
    /// enable path to arm the mix-bus servo at the rate we actually got
    /// (the 48k pin is best-effort and can fail).
    static func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    /// Input-side channel count accessor, mirroring the existing output
    /// variant. Used to identify BlackHole capture devices for sharing.
    static func inputChannelCount(deviceID: AudioDeviceID) -> Int {
        (try? channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)) ?? 0
    }
}
