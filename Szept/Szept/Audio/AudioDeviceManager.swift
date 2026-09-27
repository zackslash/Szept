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

    var errorDescription: String? {
        switch self {
        case .queryFailed(let status):
            return "Audio device query failed (code \(status))"
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

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, buffer.baseAddress
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
}
