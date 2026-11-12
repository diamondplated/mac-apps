import CoreAudio
import Foundation
import ScrollSplitCore

/// One CoreAudio input device, by its input-scope mute and volume properties.
final class CoreAudioInput: InputDeviceControl {
    let id: UInt32
    init(id: AudioObjectID) { self.id = id }

    private func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }

    private func isSettable(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var address = address(selector, element)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    // Mute is a UInt32 and volume a Float32: both plain 4-byte values.
    private func get<T: BinaryInteger>(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement, _: T.Type) -> T? {
        var address = address(selector, element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? T(value) : nil
    }

    private func getScalar(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Float32? {
        var address = address(selector, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func set(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement, _ value: UInt32) {
        var address = address(selector, element)
        var value = value
        _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func set(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement, _ value: Float32) {
        var address = address(selector, element)
        var value = value
        _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    var hasMute: Bool { isSettable(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain) }
    var isMuted: Bool { (get(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, UInt32.self) ?? 0) != 0 }
    func setMuted(_ muted: Bool) { set(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, UInt32(muted ? 1 : 0)) }

    /// The main volume where the device has one, otherwise each channel's.
    private var volumeElements: [AudioObjectPropertyElement] {
        if isSettable(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...16).map { AudioObjectPropertyElement($0) }.filter { isSettable(kAudioDevicePropertyVolumeScalar, $0) }
    }

    var volumes: [Float]? {
        let elements = volumeElements
        guard !elements.isEmpty else { return nil }
        return elements.map { getScalar(kAudioDevicePropertyVolumeScalar, $0) ?? 0 }
    }

    func setVolumes(_ volumes: [Float]) {
        for (element, volume) in zip(volumeElements, volumes) { set(kAudioDevicePropertyVolumeScalar, element, Float32(volume)) }
    }
}

/// Mute for the default input device, following it when it changes. Listens to CoreAudio
/// only while the mute shortcut is assigned or a mute is in force.
final class Microphone {
    private var muter = MicrophoneMuter()
    private var device: CoreAudioInput?
    private var listening = false
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    var didChange: (() -> Void)?

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let deviceSelectors = [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar]

    private static func defaultInput() -> CoreAudioInput? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return CoreAudioInput(id: id)
    }

    /// The default input device is muted, by ScrollSplit or anything else.
    var isMuted: Bool { (device ?? Self.defaultInput()).map(MicrophoneMuter.isMuted) ?? false }

    func toggle() {
        startListening()
        muter.reconcile(lookup: { CoreAudioInput(id: $0) })
        device = Self.defaultInput()
        muter.toggle(current: device, lookup: { CoreAudioInput(id: $0) })
        didChange?()
    }

    /// Restores every device ScrollSplit muted. Called by the menu, when ScrollSplit turns
    /// off and when it quits.
    func unmute() {
        muter.unmuteAll(lookup: { CoreAudioInput(id: $0) })
        didChange?()
    }

    var isHoldingMute: Bool { muter.isHoldingMute }

    /// Listening follows `wanted` (the shortcut is assigned and ScrollSplit is on), but never
    /// stops while a mute is in force.
    func setListening(_ wanted: Bool) {
        if wanted || muter.isHoldingMute { startListening() } else { stopListening() }
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultDeviceChanged() }
        defaultListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, .main, listener)
        device = Self.defaultInput()
        watch(device)
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        if let defaultListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, .main, defaultListener)
        }
        defaultListener = nil
        unwatch(device)
        device = nil
    }

    private func defaultDeviceChanged() {
        unwatch(device)
        device = Self.defaultInput()
        watch(device)
        muter.defaultDeviceChanged(to: device)
        didChange?()
    }

    /// Mute or volume changes from anywhere (Control Centre, the call app) refresh the icon.
    private func watch(_ device: CoreAudioInput?) {
        guard let device else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.muter.reconcile(lookup: { CoreAudioInput(id: $0) })
            self?.didChange?()
        }
        deviceListener = listener
        for selector in Self.deviceSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device.id, &address, .main, listener)
        }
    }

    private func unwatch(_ device: CoreAudioInput?) {
        guard let device, let deviceListener else { return }
        for selector in Self.deviceSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device.id, &address, .main, deviceListener)
        }
        self.deviceListener = nil
    }
}
