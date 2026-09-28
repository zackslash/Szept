import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int
}

enum AudioDeviceError: LocalizedError {
    case queryFailed(OSStatus)
    case aggregateCreateFailed

    var errorDescription: String? {
        switch self {
        case .queryFailed(let status):
            return "Audio device query failed (code \(status))"
        case .aggregateCreateFailed:
            return "Could not create the Szept aggregate device (HAL returned no device)"
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
            if let info = try deviceInfo(for: deviceID) {
                devices.append(info)
            }
        }
        return devices
    }

    static func inputDevices() throws -> [AudioDeviceInfo] {
        try allDevices().filter { $0.inputChannelCount > 0 }
    }

    static func outputDevices() throws -> [AudioDeviceInfo] {
        try allDevices().filter { $0.outputChannelCount > 0 }
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

    /// Output channel count of a device on the output scope.
    static func outputChannelCount(deviceID: AudioDeviceID) -> Int {
        (try? channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)) ?? 0
    }

    /// The system default input device (kAudioHardwarePropertyDefaultInputDevice).
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

    /// Create the private aggregate that bridges the input device (clock
    /// master) and the loopback output device onto one clock, so the engine
    /// tap (producer) and our output render (consumer) share one crystal
    /// and no drift accumulates in the ring. Any stale aggregate from a
    /// previous session is destroyed first.
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

    /// Find and destroy any aggregate carrying our stable UID (for example
    /// left behind by a crash). Reuses the existing enumeration and CFString
    /// property helpers.
    private static func findAndDestroyStaleAggregate() {
        guard let devices = try? allDevices() else { return }
        for device in devices where device.uid == aggregateUID {
            FileLog.log("aggregate: destroying stale device id \(device.id)")
            destroyAggregateDevice(id: device.id)
        }
    }
}
