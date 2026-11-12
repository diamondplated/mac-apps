import CoreAudio
import Foundation
import StayLitCore

/// The current sound output, cached so the event tap never queries Core Audio.
/// Listens for the default output device changing while it is started.
final class AudioOutputMonitor {
    private(set) var output: AudioOutput?
    private var listening = false
    private let queue = DispatchQueue.main
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update() }
    var onChange: (() -> Void)?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                                        mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard !listening else { return }
        listening = true
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, deviceListener)
        update()
    }

    func stop() {
        guard listening else { return }
        listening = false
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, deviceListener)
        output = nil
    }

    func update() {
        output = Self.read()
        onChange?()
    }

    static func read() -> AudioOutput? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &name)
        let isDisplay = transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
        return AudioOutput(name: name?.takeRetainedValue() as String? ?? "", isDisplayTransport: isDisplay, hasSystemVolume: hasSettableVolume(device))
    }

    /// macOS can change the volume when the main element or a channel has a settable volume.
    private static func hasSettableVolume(_ device: AudioObjectID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue { return true }
        }
        return false
    }

    deinit { stop() }
}
