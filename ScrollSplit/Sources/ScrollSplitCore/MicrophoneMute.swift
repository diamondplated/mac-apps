import Foundation

/// What muting needs from an input device, so the logic can run against a fake.
public protocol InputDeviceControl: AnyObject {
    /// The device's stable identity (CoreAudio's device UID), the same across launches.
    var uid: String { get }
    /// The device has a settable input mute property.
    var hasMute: Bool { get }
    var isMuted: Bool { get }
    func setMuted(_ muted: Bool)
    /// Settable input volumes (the main element, or each channel), nil when there are none.
    var volumes: [Float]? { get }
    func setVolumes(_ volumes: [Float])
}

/// Toggles mute on the default input device: the mute property where the device has one,
/// otherwise its input volume to zero and back. Every device ScrollSplit muted is
/// remembered so unmuting (including at quit) restores each one exactly, and a new
/// default device is muted too while a mute is in force, so plugging in a headset never
/// unmutes a call.
///
/// With a store, every change to the ledger is saved at once, so a crash leaves a record that
/// `recover` undoes at the next launch: a mute never outlives ScrollSplit.
public struct MicrophoneMuter {
    public enum Restoration: Codable, Equatable { case unmute, volumes([Float]) }

    public private(set) var ledger: [String: Restoration] = [:] {
        didSet { if ledger != oldValue { store?.save(ledger) } }
    }
    private let store: MuteRecordStore?
    public init(store: MuteRecordStore? = nil) { self.store = store }

    /// Undoes a mute left by a run that ended without unmuting (a crash), then drops the
    /// record. Only devices in the record are touched; one no longer present is skipped.
    public static func recover(store: MuteRecordStore, lookup: (String) -> InputDeviceControl?) {
        let record = store.load()
        guard !record.isEmpty else { return }
        for (uid, restoration) in record { if let device = lookup(uid) { unmute(device, restoration: restoration) } }
        store.clear()
    }

    /// A mute ScrollSplit applied is in force.
    public var isHoldingMute: Bool { !ledger.isEmpty }

    /// Whether the device is muted, by whichever means it supports.
    public static func isMuted(_ device: InputDeviceControl) -> Bool {
        if device.hasMute { return device.isMuted }
        guard let volumes = device.volumes, !volumes.isEmpty else { return false }
        return volumes.allSatisfy { $0 == 0 }
    }

    /// Mutes or unmutes by the current device's actual state. Returns whether it is now muted.
    @discardableResult
    public mutating func toggle(current: InputDeviceControl?, lookup: (String) -> InputDeviceControl?) -> Bool {
        guard let current else { unmuteAll(lookup: lookup); return false }
        if Self.isMuted(current) {
            unmuteAll(lookup: lookup)
            // Muted by something else: unmute it too, since that is what the key asks for.
            if Self.isMuted(current) { Self.unmute(current, restoration: nil) }
            return Self.isMuted(current)
        }
        mute(current)
        return Self.isMuted(current)
    }

    /// Returns whether the device is muted afterwards. A device with neither a mute nor a
    /// settable volume cannot be muted, and the caller must not claim it is.
    @discardableResult
    public mutating func mute(_ device: InputDeviceControl) -> Bool {
        if device.hasMute {
            if !device.isMuted {
                device.setMuted(true)
                ledger[device.uid] = .unmute
            }
        } else if let volumes = device.volumes, !volumes.isEmpty, volumes.contains(where: { $0 > 0 }) {
            if ledger[device.uid] == nil { ledger[device.uid] = .volumes(volumes) }
            device.setVolumes(volumes.map { _ in 0 })
        }
        return Self.isMuted(device)
    }

    /// Forgets devices that something else has unmuted since (Control Centre, the call app),
    /// so ScrollSplit neither claims they are muted nor mutes them again on a device change.
    public mutating func reconcile(lookup: (String) -> InputDeviceControl?) {
        ledger = ledger.filter { uid, _ in lookup(uid).map(Self.isMuted) ?? true }
    }

    /// The default input device changed; keep a mute in force on the new one.
    public mutating func defaultDeviceChanged(to device: InputDeviceControl?) {
        guard isHoldingMute, let device else { return }
        mute(device)
    }

    /// Restores every device ScrollSplit muted that still exists. Used by the key, the
    /// menu, turning ScrollSplit off and quitting.
    public mutating func unmuteAll(lookup: (String) -> InputDeviceControl?) {
        for (uid, restoration) in ledger { if let device = lookup(uid) { Self.unmute(device, restoration: restoration) } }
        ledger.removeAll()
    }

    /// With no record (muted by something else), a zero volume comes back at full level.
    private static func unmute(_ device: InputDeviceControl, restoration: Restoration?) {
        switch restoration {
        case .unmute: if device.hasMute { device.setMuted(false) }
        case .volumes(let volumes): if device.volumes != nil { device.setVolumes(volumes) }
        case nil:
            if device.hasMute { device.setMuted(false) }
            else if let volumes = device.volumes { device.setVolumes(volumes.map { _ in 1 }) }
        }
    }
}

/// The saved record of what ScrollSplit muted: device UID, and either "unmute" or the
/// volumes to put back. Kept in ScrollSplit's own preferences; tests pass a private suite.
public final class MuteRecordStore {
    public static let key = "microphoneMuteRecord"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> [String: MicrophoneMuter.Restoration] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: MicrophoneMuter.Restoration].self, from: $0) } ?? [:]
    }

    public func save(_ record: [String: MicrophoneMuter.Restoration]) {
        if record.isEmpty { clear(); return }
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.key) }
    }

    public func clear() { defaults.removeObject(forKey: Self.key) }
}
