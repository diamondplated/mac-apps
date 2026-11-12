import Foundation

/// What muting needs from an input device, so the logic can run against a fake.
public protocol InputDeviceControl: AnyObject {
    var id: UInt32 { get }
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
public struct MicrophoneMuter {
    public enum Restoration: Equatable { case unmute, volumes([Float]) }

    public private(set) var ledger: [UInt32: Restoration] = [:]
    public init() {}

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
    public mutating func toggle(current: InputDeviceControl?, lookup: (UInt32) -> InputDeviceControl?) -> Bool {
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

    public mutating func mute(_ device: InputDeviceControl) {
        if device.hasMute {
            guard !device.isMuted else { return }
            device.setMuted(true)
            ledger[device.id] = .unmute
        } else if let volumes = device.volumes, !volumes.isEmpty {
            guard volumes.contains(where: { $0 > 0 }) else { return }
            if ledger[device.id] == nil { ledger[device.id] = .volumes(volumes) }
            device.setVolumes(volumes.map { _ in 0 })
        }
    }

    /// The default input device changed; keep a mute in force on the new one.
    public mutating func defaultDeviceChanged(to device: InputDeviceControl?) {
        guard isHoldingMute, let device else { return }
        mute(device)
    }

    /// Restores every device ScrollSplit muted that still exists. Used by the key, the
    /// menu, turning ScrollSplit off and quitting.
    public mutating func unmuteAll(lookup: (UInt32) -> InputDeviceControl?) {
        for (id, restoration) in ledger { if let device = lookup(id) { Self.unmute(device, restoration: restoration) } }
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
