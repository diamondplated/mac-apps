import CoreAudio
import Darwin
import Foundation
import MixBarCore
import MixBarDSP

/// The real audio system. Reads process objects and devices, and builds one chain per
/// tapped app: a private process tap that silences the app only while MixBar reads it,
/// a private aggregate device of that tap and the chosen output, and an IO callback
/// that replays the tap at the chosen gain.
///
/// Fail-open design, from the SDK headers:
/// - `CATapMutedWhenTapped`: the app is silenced only "for the duration of the read
///   activity on the tap". If MixBar stops reading (quits, crashes, IO stops), the app's
///   own sound goes to the hardware again. `CATapMuted` would mute for the tap's whole
///   life, so it is never used.
/// - The tap is private (`privateTap`, visible only to MixBar) and the aggregate device is
///   private ("not persistent across launches of the process that created it").
final class CoreAudioSystem: AudioService {
    static let aggregatePrefix = "com.andrew.mixbar.aggregate."

    private final class Chain {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var outputID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var state: OpaquePointer?
        var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    }

    private var chains: [TapHandle: Chain] = [:]
    private var nextHandle: UInt64 = 1
    private var systemListeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    /// A live chain broke: its output vanished or changed rate, or the tap's format changed.
    var onTapFailure: ((TapHandle) -> Void)?
    /// Processes, devices or the default output changed.
    var onChange: (() -> Void)?
    /// coreaudiod restarted; every object ID is stale.
    var onServiceRestart: (() -> Void)?

    var tapsAvailable: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    // MARK: Reading

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func objectIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)

    func processes() -> [AudioProcess] {
        guard tapsAvailable else { return [] }
        return Self.objectIDs(Self.system, Self.address(kAudioHardwarePropertyProcessObjectList)).compactMap { id in
            guard let pid = Self.value(id, Self.address(kAudioProcessPropertyPID), initial: pid_t(0)), pid > 0 else { return nil }
            let running = Self.value(id, Self.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0)) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleIdentifier: Self.string(id, Self.address(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 },
                                executablePath: Self.executablePath(pid), isRunningOutput: running != 0)
        }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        objectIDs(device, address(kAudioDevicePropertyStreams, scope)).count
    }

    static func uid(of device: AudioObjectID) -> String? { string(device, address(kAudioDevicePropertyDeviceUID)) }

    /// Visible output devices, without MixBar's own aggregates.
    func outputDevices() -> [OutputDevice] {
        Self.objectIDs(Self.system, Self.address(kAudioHardwarePropertyDevices)).compactMap { device in
            guard Self.streamCount(device, kAudioObjectPropertyScopeOutput) > 0,
                  (Self.value(device, Self.address(kAudioDevicePropertyIsHidden), initial: UInt32(0)) ?? 0) == 0,
                  let uid = Self.uid(of: device), !uid.hasPrefix(Self.aggregatePrefix) else { return nil }
            return OutputDevice(uid: uid, name: Self.string(device, Self.address(kAudioObjectPropertyName)) ?? uid)
        }
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        objectIDs(system, address(kAudioHardwarePropertyDevices)).first { Self.uid(of: $0) == uid }
    }

    var defaultOutputID: AudioObjectID? {
        guard let id = Self.value(Self.system, Self.address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID(0)), id != 0 else { return nil }
        return id
    }

    func defaultOutputUID() -> String? { defaultOutputID.flatMap(Self.uid(of:)) }

    // MARK: System output volume (only on a user's drag)

    /// The elements that carry the device's output volume: the main element, or else its first two channels.
    private static func volumeElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        for elements in [[kAudioObjectPropertyElementMain], [1, 2] as [AudioObjectPropertyElement]] {
            let present = elements.filter { element in
                var address = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
                return AudioObjectHasProperty(device, &address)
            }
            if !present.isEmpty { return present }
        }
        return []
    }

    func systemOutput() -> MixerViewModel.SystemOutput? {
        guard let device = defaultOutputID else { return nil }
        let name = Self.string(device, Self.address(kAudioObjectPropertyName)) ?? "Output"
        let volumes = Self.volumeElements(device).compactMap {
            Self.value(device, Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, $0), initial: Float32(0))
        }
        return MixerViewModel.SystemOutput(name: name, volume: volumes.isEmpty ? nil : Double(volumes.max() ?? 0))
    }

    func setSystemVolume(_ volume: Double) {
        guard let device = defaultOutputID else { return }
        for element in Self.volumeElements(device) {
            var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var value = Float32(min(max(volume, 0), 1))
            _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    // MARK: System listeners

    func startListening() {
        guard systemListeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyServiceRestarted] {
            var address = Self.address(selector)
            let restart = selector == kAudioHardwarePropertyServiceRestarted
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                if restart { self?.onServiceRestart?() } else { self?.onChange?() }
            }
            if AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, block) == noErr { systemListeners.append((address, block)) }
        }
    }

    func stopListening() {
        for (address, block) in systemListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(Self.system, &address, .main, block)
        }
        systemListeners.removeAll()
    }

    // MARK: Taps

    func createTap(_ spec: TapSpec, gain: Float) throws -> TapHandle {
        guard #available(macOS 14.2, *) else { throw TapError.unavailable }
        let chain = Chain()
        do {
            try build(chain, spec: spec, gain: gain)
        } catch {
            teardown(chain)
            throw error
        }
        let handle = TapHandle(nextHandle)
        nextHandle += 1
        chains[handle] = chain
        watch(chain, handle: handle)
        return handle
    }

    private static func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        throw status == kAudioDevicePermissionsError ? TapError.permissionDenied : TapError.failed(status)
    }

    private static func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
    }

    @available(macOS 14.2, *)
    private func build(_ chain: Chain, spec: TapSpec, gain: Float) throws {
        guard !spec.processObjectIDs.isEmpty, let outputID = Self.deviceID(forUID: spec.outputDeviceUID) else { throw TapError.failed(-1) }
        chain.outputID = outputID

        let description = CATapDescription(__stereoMixdownOfProcesses: spec.processObjectIDs.map { NSNumber(value: $0) })
        description.name = "MixBar"
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID))
        chain.tapID = tapID
        guard let tapFormat = Self.value(tapID, Self.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription()),
              Self.isFloat32(tapFormat) else { throw TapError.failed(-2) }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MixBar",
            kAudioAggregateDeviceUIDKey: Self.aggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: spec.outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: spec.outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID))
        chain.aggregateID = aggregateID

        // Every output stream the callback writes must be 32-bit float.
        let outputStreams = Self.objectIDs(aggregateID, Self.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput))
        guard !outputStreams.isEmpty, outputStreams.allSatisfy({ stream in
            Self.value(stream, Self.address(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()).map(Self.isFloat32) ?? false
        }) else { throw TapError.failed(-3) }

        let rate = Self.value(aggregateID, Self.address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)) ?? 0
        // Start where the untapped app was, at 100 percent, and ramp to the setting.
        guard let state = mb_render_state_create(rate, 1) else { throw TapError.failed(-4) }
        chain.state = state
        mb_set_target_gain(state, gain)

        // The callback captures only the C render state: no reference counting, allocation,
        // locks, Objective-C messaging or logging on the real-time thread.
        var procID: AudioDeviceIOProcID?
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            mb_render(state, input, output)
        })
        chain.procID = procID
        guard let procID else { throw TapError.failed(-5) }

        try Self.useOnlyTapInput(aggregate: aggregateID, output: outputID, procID: procID)
        try Self.check(AudioDeviceStart(aggregateID, procID))
    }

    /// The aggregate's input is the output device's own input streams (a headset's
    /// microphone, say), then the tap. Turns the device's input streams off for this
    /// callback so MixBar never reads a microphone; only the tap's streams stay on.
    private static func useOnlyTapInput(aggregate: AudioObjectID, output: AudioObjectID, procID: AudioDeviceIOProcID) throws {
        let total = streamCount(aggregate, kAudioObjectPropertyScopeInput)
        let deviceInputs = streamCount(output, kAudioObjectPropertyScopeInput)
        guard total > deviceInputs else { throw TapError.failed(-6) }
        guard deviceInputs > 0 else { return }
        let size = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size * (1 + total)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        let counts = raw.advanced(by: MemoryLayout<UnsafeMutableRawPointer>.size)
        counts.storeBytes(of: UInt32(total), as: UInt32.self)
        for index in 0..<total {
            counts.storeBytes(of: index < deviceInputs ? 0 : 1, toByteOffset: MemoryLayout<UInt32>.size * (1 + index), as: UInt32.self)
        }
        var address = Self.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), raw))
    }

    /// Any of these changing means the chain must be rebuilt or removed.
    private func watch(_ chain: Chain, handle: TapHandle) {
        var watched: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (chain.outputID, Self.address(kAudioDevicePropertyDeviceIsAlive)),
            (chain.outputID, Self.address(kAudioDevicePropertyNominalSampleRate)),
            (chain.aggregateID, Self.address(kAudioDevicePropertyDeviceIsAlive))
        ]
        if #available(macOS 14.2, *) { watched.append((chain.tapID, Self.address(kAudioTapPropertyFormat))) }
        for (object, address) in watched {
            var address = address
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onTapFailure?(handle) }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { chain.listeners.append((object, address, block)) }
        }
    }

    func destroyTap(_ handle: TapHandle) {
        guard let chain = chains.removeValue(forKey: handle) else { return }
        teardown(chain)
    }

    private func teardown(_ chain: Chain) {
        for (object, address, block) in chain.listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        chain.listeners.removeAll()
        if let procID = chain.procID {
            AudioDeviceStop(chain.aggregateID, procID)
            AudioDeviceDestroyIOProcID(chain.aggregateID, procID)
            chain.procID = nil
        }
        if chain.aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(chain.aggregateID)
            chain.aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if chain.tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(chain.tapID) }
            chain.tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let state = chain.state {
            chain.state = nil
            // The IO proc is stopped and destroyed; free the state a moment later regardless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { mb_render_state_destroy(state) }
        }
    }

    func setGain(_ gain: Float, for handle: TapHandle) {
        guard let state = chains[handle]?.state else { return }
        mb_set_target_gain(state, gain)
    }

    func health(of handle: TapHandle) -> TapHealth {
        guard let state = chains[handle]?.state else { return TapHealth(framesRendered: 0, sawSignal: false) }
        return TapHealth(framesRendered: mb_frames_rendered(state), sawSignal: mb_saw_signal(state))
    }

    func destroyAll() {
        for handle in Array(chains.keys) { destroyTap(handle) }
    }
}
