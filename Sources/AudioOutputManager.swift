//
//  AudioOutputManager.swift
//  StudyCast
//
//  Enumerates macOS CoreAudio output devices for per-station monitoring.
//

import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Equatable {
    static let systemDefaultUID = "StudyCast.audioOutput.systemDefault"

    let uid: String
    let audioDeviceID: Int?
    let name: String
    let isSystemDefault: Bool
    let isAvailable: Bool

    var id: String { uid }

    static let systemDefault = AudioOutputDevice(
        uid: systemDefaultUID,
        audioDeviceID: 0,
        name: "System Default",
        isSystemDefault: true,
        isAvailable: true
    )

    static func unavailable(uid: String) -> AudioOutputDevice {
        AudioOutputDevice(
            uid: uid,
            audioDeviceID: nil,
            name: "Missing output device",
            isSystemDefault: false,
            isAvailable: false
        )
    }
}

@MainActor
final class AudioOutputManager: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = [.systemDefault]

    init() {
        refresh()
    }

    func refresh() {
        devices = [.systemDefault] + Self.enumerateOutputDevices()
    }

    func outputDeviceID(for uid: String) -> Int? {
        if uid == AudioOutputDevice.systemDefaultUID {
            return 0
        }
        return devices.first { $0.uid == uid && $0.isAvailable }?.audioDeviceID
    }

    func isAvailable(uid: String) -> Bool {
        uid == AudioOutputDevice.systemDefaultUID
            || devices.contains { $0.uid == uid && $0.isAvailable }
    }

    func pickerDevices(including selectedUID: String) -> [AudioOutputDevice] {
        guard selectedUID != AudioOutputDevice.systemDefaultUID,
              !devices.contains(where: { $0.uid == selectedUID }) else {
            return devices
        }
        return devices + [.unavailable(uid: selectedUID)]
    }

    private static func enumerateOutputDevices() -> [AudioOutputDevice] {
        let deviceIDs = allAudioDeviceIDs()

        return deviceIDs.compactMap { deviceID in
            guard outputChannelCount(for: deviceID) > 0,
                  let uid = stringProperty(
                    selector: kAudioDevicePropertyDeviceUID,
                    objectID: deviceID
                  ) else {
                return nil
            }

            let name = stringProperty(
                selector: kAudioObjectPropertyName,
                objectID: deviceID
            ) ?? "Audio Device \(deviceID)"

            return AudioOutputDevice(
                uid: uid,
                audioDeviceID: Int(deviceID),
                name: name,
                isSystemDefault: false,
                isAvailable: true
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return OSStatus(kAudioHardwareBadObjectError)
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }

        return status == noErr ? deviceIDs : []
    }

    private static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            bufferList
        ) == noErr else {
            return 0
        }

        return UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }

        guard status == noErr else { return nil }
        return value as String
    }
}
