import Foundation

public enum MediaKey: Hashable {
    case brightnessUp, brightnessDown, volumeUp, volumeDown, mute
}

/// A system-defined event (type 14) carrying a media key: subtype 8, with the key
/// type in the high half of data1 and the key state in bits 8–15 (0x0A down, 0x0B up).
public struct MediaKeyEvent: Equatable {
    public static let systemDefinedType: UInt32 = 14
    public static let auxControlSubtype: Int16 = 8

    public let key: MediaKey
    public let isDown: Bool
    public let isRepeat: Bool

    public init(key: MediaKey, isDown: Bool, isRepeat: Bool) { self.key = key; self.isDown = isDown; self.isRepeat = isRepeat }

    public init?(subtype: Int16, data1: Int) {
        guard subtype == Self.auxControlSubtype else { return nil }
        let keyType = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0x0A || state == 0x0B else { return nil }
        switch keyType {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        case 7: key = .mute
        default: return nil
        }
        isDown = state == 0x0A
        isRepeat = flags & 0x1 != 0
    }
}

/// A connected display as the key router sees it.
public struct DisplayInfo: Equatable {
    public static let appleVendor: UInt32 = 0x0610

    public var id: UInt32
    public var name: String
    public var isBuiltin: Bool
    public var vendor: UInt32
    /// The display answered a brightness read over DDC/CI.
    public var brightness: DDC.Value?
    /// The display answered a volume read over DDC/CI.
    public var volume: DDC.Value?

    public init(id: UInt32, name: String, isBuiltin: Bool, vendor: UInt32, brightness: DDC.Value? = nil, volume: DDC.Value? = nil) {
        self.id = id; self.name = name; self.isBuiltin = isBuiltin; self.vendor = vendor
        self.brightness = brightness; self.volume = volume
    }

    /// The built-in display and Apple displays are already controlled by macOS.
    public var systemControlsBrightness: Bool { isBuiltin || vendor == Self.appleVendor }
    public var isExternal: Bool { !isBuiltin }
    public var controllable: Bool { !systemControlsBrightness && (brightness != nil || volume != nil) }
}

/// The current sound output device, as far as volume keys care.
public struct AudioOutput: Equatable {
    public var name: String
    /// HDMI or DisplayPort.
    public var isDisplayTransport: Bool
    /// macOS can set this device's volume itself.
    public var hasSystemVolume: Bool
    public init(name: String, isDisplayTransport: Bool, hasSystemVolume: Bool) {
        self.name = name; self.isDisplayTransport = isDisplayTransport; self.hasSystemVolume = hasSystemVolume
    }
}

public enum VolumeTarget {
    /// The display whose own volume the volume keys should change, or nil to leave them to macOS.
    /// The output must be a display connection with no system volume; it is matched to a
    /// display by name, or to the only external display that answers volume reads.
    public static func resolve(output: AudioOutput?, displays: [DisplayInfo]) -> UInt32? {
        guard let output, output.isDisplayTransport, !output.hasSystemVolume else { return nil }
        let candidates = displays.filter { !$0.systemControlsBrightness && $0.volume != nil }
        let name = output.name.trimmingCharacters(in: .whitespaces).lowercased()
        if !name.isEmpty {
            let named = candidates.filter { $0.name.lowercased() == name }
            if named.count == 1 { return named[0].id }
            let partial = candidates.filter { $0.name.lowercased().contains(name) || name.contains($0.name.lowercased()) }
            if partial.count == 1 { return partial[0].id }
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }
}

public enum KeyClaim: Equatable {
    case pass
    case brightness(display: UInt32, up: Bool)
    case volume(display: UInt32, up: Bool)
    case mute(display: UInt32)

    /// Up events and repeats of a claimed key are swallowed too; only a down or a repeat acts.
    public var claimsEvent: Bool { self != .pass }
}

public enum KeyRouter {
    /// Claims a key only when its switch is on and a display that answers DDC/CI is the
    /// target; everything else passes through to macOS untouched.
    public static func decide(_ key: MediaKey, pointerDisplay: DisplayInfo?, volumeDisplay: UInt32?,
                              displays: [DisplayInfo], brightnessOn: Bool, volumeOn: Bool) -> KeyClaim {
        switch key {
        case .brightnessUp, .brightnessDown:
            guard brightnessOn, let display = pointerDisplay, !display.systemControlsBrightness, display.brightness != nil else { return .pass }
            return .brightness(display: display.id, up: key == .brightnessUp)
        case .volumeUp, .volumeDown, .mute:
            guard volumeOn, let id = volumeDisplay, displays.contains(where: { $0.id == id && $0.volume != nil && !$0.systemControlsBrightness }) else { return .pass }
            return key == .mute ? .mute(display: id) : .volume(display: id, up: key == .volumeUp)
        }
    }
}

/// Pairs a display's DDC channel, found in the I/O registry with its EDID attributes,
/// to a connected display.
public struct ChannelAttributes: Equatable {
    public var vendor: UInt32
    public var product: UInt32
    public var serial: UInt32
    public init(vendor: UInt32, product: UInt32, serial: UInt32) { self.vendor = vendor; self.product = product; self.serial = serial }
}

public enum ChannelMatcher {
    /// Returns, for each channel index, the display id it belongs to. Vendor and product
    /// must agree; a serial breaks ties when both sides have one. Identical displays
    /// without serials pair in order. A lone external display with a lone channel pairs
    /// even when the attributes are missing.
    public static func match(channels: [ChannelAttributes?], displays: [(id: UInt32, attributes: ChannelAttributes)]) -> [Int: UInt32] {
        var result: [Int: UInt32] = [:]
        var taken = Set<UInt32>()
        for (index, channel) in channels.enumerated() {
            guard let channel else { continue }
            let same = displays.filter { !taken.contains($0.id) && $0.attributes.vendor == channel.vendor && $0.attributes.product == channel.product }
            let pick = same.first { channel.serial != 0 && $0.attributes.serial == channel.serial }
                ?? same.first { channel.serial == 0 || $0.attributes.serial == 0 }
            if let pick { result[index] = pick.id; taken.insert(pick.id) }
        }
        if result.isEmpty, channels.count == 1, displays.count == 1 { result[0] = displays[0].id }
        return result
    }
}

/// What the tap does with one event. A key's up follows its down: it is swallowed only
/// when that down was claimed, so macOS never sees half a press. Everything else passes.
public struct MediaKeyGate {
    public enum Action: Equatable { case pass, swallow, act(KeyClaim) }
    public private(set) var claimedDowns = Set<MediaKey>()
    public init() {}

    public mutating func handle(_ event: MediaKeyEvent?, wanted: Bool, claim: (MediaKey) -> KeyClaim) -> Action {
        guard wanted else { claimedDowns.removeAll(); return .pass }
        guard let event else { return .pass }
        if event.isDown {
            let decision = claim(event.key)
            guard decision.claimsEvent else { claimedDowns.remove(event.key); return .pass }
            claimedDowns.insert(event.key)
            return .act(decision)
        }
        return claimedDowns.remove(event.key) != nil ? .swallow : .pass
    }
}
