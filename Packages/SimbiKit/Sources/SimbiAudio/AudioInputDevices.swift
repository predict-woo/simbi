import CoreAudio
import Foundation

/// A selectable audio input device (SPEC.md §3.1: the mic picker lists
/// these). `id` is the CoreAudio device UID — stable across launches and
/// unplugs, which is why it (not the transient AudioDeviceID) is persisted
/// in settings.
public struct AudioInputDevice: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// CoreAudio HAL enumeration of input-capable devices.
public enum AudioInputDevices {
    /// All devices with at least one input stream, in HAL order.
    public static func list() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard hasInputStreams(deviceID),
                let uid: String = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                let name: String = stringProperty(deviceID, selector: kAudioObjectPropertyName),
                // CoreAudio publishes a transient aggregate for each app's
                // own engine ("CADefaultDeviceAggregate-<pid>-…") — an
                // artifact, not a pickable mic.
                !uid.hasPrefix("CADefaultDeviceAggregate")
            else { return nil }
            return AudioInputDevice(id: uid, name: name)
        }
    }

    /// Resolves a persisted UID back to the HAL's transient device id;
    /// nil when the device isn't currently connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first {
            stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
