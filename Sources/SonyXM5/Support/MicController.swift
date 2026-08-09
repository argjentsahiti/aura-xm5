import Foundation
import CoreAudio
import AudioToolbox

/// Microphone level for the headset.
///
/// The XM5's own control protocol exposes no microphone gain — Sony's app has no
/// such control either. What *is* controllable is the input gain macOS applies to
/// the headset when it's the active input device, which is the level that
/// actually reaches Zoom, Meet and every other app. That's what this adjusts, via
/// CoreAudio.
///
/// The headset only appears as an input device while the Bluetooth link is in
/// hands-free (HFP) mode — i.e. when something is actually using the mic.
@MainActor
final class MicController: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var volume: Float = 0      // 0…1
    @Published private(set) var isMuted = false
    @Published private(set) var deviceName: String?

    private var deviceID: AudioDeviceID?
    private var pollTimer: Timer?

    init() {
        refresh()
        // The device appears and disappears as HFP engages, so poll rather than
        // assume it's there.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { pollTimer?.invalidate() }

    // MARK: Discovery

    func refresh() {
        guard let id = findHeadsetInput() else {
            isAvailable = false
            deviceID = nil
            deviceName = nil
            return
        }
        deviceID = id
        deviceName = name(of: id)
        isAvailable = true
        volume = readVolume(id) ?? volume
        isMuted = readMute(id) ?? isMuted
    }

    private func findHeadsetInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for device in devices {
            guard hasInput(device), let n = name(of: device) else { continue }
            if SupportedDevices.nameHints.contains(where: { n.contains($0) }) {
                return device
            }
        }
        return nil
    }

    private func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio hands back a +1 retained CFStringRef, so take ownership
        // rather than binding a raw pointer to a managed CFString.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    // MARK: Volume

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readVolume(_ device: AudioDeviceID) -> Float? {
        var address = volumeAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
            return value
        }
        // Some devices only expose per-channel volume.
        address.mElement = 1
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
            return value
        }
        return nil
    }

    func setVolume(_ newValue: Float) {
        guard let device = deviceID else { return }
        let clamped = max(0, min(1, newValue))
        volume = clamped

        var address = volumeAddress()
        var value = Float32(clamped)
        let size = UInt32(MemoryLayout<Float32>.size)

        var status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if status != noErr {
            // Fall back to writing each channel.
            for channel in UInt32(1)...2 {
                address.mElement = channel
                status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
            }
        }
        if status != noErr {
            Log.write("mic", "set volume failed: \(status)")
        }
    }

    // MARK: Mute

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readMute(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    func setMuted(_ muted: Bool) {
        guard let device = deviceID else { return }
        isMuted = muted
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if status != noErr {
            Log.write("mic", "set mute failed: \(status)")
        }
    }
}
