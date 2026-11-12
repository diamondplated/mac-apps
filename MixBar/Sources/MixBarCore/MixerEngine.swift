import Foundation

/// What one tap replays: these process objects, to this output device.
public struct TapSpec: Equatable {
    public var bundleIdentifier: String
    public var processObjectIDs: [UInt32]
    public var outputDeviceUID: String
    public init(bundleIdentifier: String, processObjectIDs: [UInt32], outputDeviceUID: String) {
        self.bundleIdentifier = bundleIdentifier; self.processObjectIDs = processObjectIDs.sorted(); self.outputDeviceUID = outputDeviceUID
    }
}

public struct TapHandle: Hashable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

/// Read from the render state without touching the IO thread.
public struct TapHealth: Equatable {
    public var framesRendered: UInt64
    public var sawSignal: Bool
    public init(framesRendered: UInt64, sawSignal: Bool) { self.framesRendered = framesRendered; self.sawSignal = sawSignal }
}

public enum TapError: Error, Equatable {
    case unavailable
    case permissionDenied
    case failed(Int32)
}

/// Whether macOS lets MixBar hear other apps. There is no public way to ask, so it is
/// learned from what happens: unknown until the first tap, then granted when sound
/// arrives or denied when it does not.
public enum CaptureStatus: String, Equatable {
    case unknown, granted, denied
}

/// Everything that touches Core Audio. The app supplies the real one; tests a fake.
public protocol AudioService: AnyObject {
    /// False below macOS 14.2, where process taps do not exist.
    var tapsAvailable: Bool { get }
    /// Creates the tap, its private aggregate device and IO, and starts it at `gain`.
    /// Either the whole chain runs or nothing is left behind.
    func createTap(_ spec: TapSpec, gain: Float) throws -> TapHandle
    /// Stops and removes everything `createTap` made. Safe to call on a handle that already failed.
    func destroyTap(_ handle: TapHandle)
    func setGain(_ gain: Float, for handle: TapHandle)
    func health(of handle: TapHandle) -> TapHealth
}

/// The audio world at one moment, as the app reads it.
public struct AudioSnapshot: Equatable {
    public var groups: [AppGroup]
    public var outputs: [OutputDevice]
    public var defaultOutputUID: String?
    public init(groups: [AppGroup], outputs: [OutputDevice], defaultOutputUID: String?) {
        self.groups = groups; self.outputs = outputs; self.defaultOutputUID = defaultOutputUID
    }
    public func group(_ bundleIdentifier: String) -> AppGroup? { groups.first { $0.bundleIdentifier == bundleIdentifier } }
}

public enum TapPlanner {
    /// The tap an app needs, or nil when MixBar leaves it alone: an app at 100 percent,
    /// unmuted, following the system output is never tapped. A chosen output that is not
    /// connected falls back to the system output.
    public static func spec(for group: AppGroup, setting: AppVolume?, outputs: [OutputDevice], defaultOutputUID: String?) -> TapSpec? {
        guard let setting, !group.processObjectIDs.isEmpty, let defaultOutputUID else { return nil }
        let pinned = setting.outputDeviceUID.flatMap { uid in outputs.contains { $0.uid == uid } ? uid : nil }
        guard setting.volume != 1 || setting.muted || pinned != nil else { return nil }
        return TapSpec(bundleIdentifier: group.bundleIdentifier, processObjectIDs: group.processObjectIDs, outputDeviceUID: pinned ?? defaultOutputUID)
    }
}

/// Which setting applies to an app right now. With remembering on, the saved setting;
/// with it off, only what was chosen in the mixer since the app started playing.
public enum SettingResolver {
    public static func effective(_ bundleIdentifier: String, settings: MixBarSettings, session: [String: AppVolume]) -> AppVolume? {
        if settings.remembersVolumes { return settings.saved(bundleIdentifier) }
        return session[bundleIdentifier]
    }
}

/// Keeps exactly the taps the settings call for, and fails open: every failure ends in
/// a rebuilt tap or no tap, never an app muted with nothing replaying it.
public final class MixerEngine {
    public struct LiveTap: Equatable {
        public var handle: TapHandle
        public var spec: TapSpec
        public var gain: Float
        public var createdAt: Date
        public var lastFrames: UInt64 = 0
        public var lastProgressAt: Date
        public var lastPlayingAt: Date
        /// How many times this tap was rebuilt after a failure; one is allowed.
        public var rebuilds = 0
    }

    /// A tap stays this long after its app stops playing, so a pause between tracks does not churn it.
    public static let idleGrace: TimeInterval = 10
    /// A tap that hears only silence this long while its app plays is removed (capture may be refused).
    public static let permissionTimeout: TimeInterval = 4
    /// IO that renders nothing this long has stalled.
    public static let stallTimeout: TimeInterval = 2
    /// A rebuilt tap that has run this long earns another rebuild.
    public static let stableAfter: TimeInterval = 30
    /// A tap removed for hearing only silence is tried again after this long.
    public static let silentRetry: TimeInterval = 30

    public let service: AudioService
    public private(set) var live: [String: LiveTap] = [:]
    /// Specs that failed; not retried until the spec changes, failures are cleared, or
    /// (for a tap removed for silence) its retry time passes.
    public private(set) var failed: [String: TapSpec] = [:]
    private var retryAt: [String: Date] = [:]
    public private(set) var captureStatus: CaptureStatus
    public var onCaptureStatusChange: ((CaptureStatus) -> Void)?

    public init(service: AudioService, captureStatus: CaptureStatus = .unknown) {
        self.service = service
        self.captureStatus = captureStatus
    }

    // MARK: Reconciling

    /// Creates, rebuilds and removes taps so they match the settings.
    public func reconcile(_ snapshot: AudioSnapshot, settings: (String) -> AppVolume?, now: Date) {
        var desired: [String: (spec: TapSpec, gain: Float)] = [:]
        if service.tapsAvailable {
            for group in snapshot.groups {
                let setting = settings(group.bundleIdentifier)
                guard let spec = TapPlanner.spec(for: group, setting: setting, outputs: snapshot.outputs, defaultOutputUID: snapshot.defaultOutputUID),
                      let setting else { continue }
                let existing = live[group.bundleIdentifier]
                let recentlyPlaying = existing.map { now.timeIntervalSince($0.lastPlayingAt) < Self.idleGrace } ?? false
                guard group.isPlaying || recentlyPlaying else { continue }
                desired[group.bundleIdentifier] = (spec, setting.gain)
            }
        }
        for (bundle, tap) in live where desired[bundle] == nil {
            service.destroyTap(tap.handle)
            live[bundle] = nil
        }
        for bundle in failed.keys where desired[bundle]?.spec != failed[bundle] || retryAt[bundle].map({ now >= $0 }) == true {
            failed[bundle] = nil
        }
        retryAt = retryAt.filter { failed[$0.key] != nil }
        for (bundle, want) in desired.sorted(by: { $0.key < $1.key }) {
            let playing = snapshot.group(bundle)?.isPlaying ?? false
            if var tap = live[bundle], tap.spec == want.spec {
                if tap.gain != want.gain { service.setGain(want.gain, for: tap.handle); tap.gain = want.gain }
                if playing { tap.lastPlayingAt = now }
                live[bundle] = tap
                continue
            }
            if let tap = live[bundle] {
                service.destroyTap(tap.handle)
                live[bundle] = nil
            }
            guard failed[bundle] != want.spec else { continue }
            create(want.spec, gain: want.gain, now: now)
        }
    }

    /// Moves live taps to new gains at once, without creating or removing any, for slider drags.
    public func updateGains(settings: (String) -> AppVolume?) {
        for (bundle, var tap) in live {
            guard let gain = settings(bundle)?.gain, gain != tap.gain else { continue }
            service.setGain(gain, for: tap.handle)
            tap.gain = gain
            live[bundle] = tap
        }
    }

    @discardableResult
    private func create(_ spec: TapSpec, gain: Float, now: Date, rebuilds: Int = 0) -> Bool {
        do {
            let handle = try service.createTap(spec, gain: gain)
            live[spec.bundleIdentifier] = LiveTap(handle: handle, spec: spec, gain: gain, createdAt: now, lastProgressAt: now, lastPlayingAt: now, rebuilds: rebuilds)
            failed[spec.bundleIdentifier] = nil
            retryAt[spec.bundleIdentifier] = nil
            return true
        } catch TapError.permissionDenied {
            failed[spec.bundleIdentifier] = spec
            setCaptureStatus(.denied)
            return false
        } catch {
            failed[spec.bundleIdentifier] = spec
            return false
        }
    }

    // MARK: Failures

    /// A live tap broke (its device vanished, its format changed, its IO stalled):
    /// rebuild it once; if that fails or it breaks again, remove it.
    public func tapFailed(_ bundleIdentifier: String, now: Date) {
        guard let tap = live[bundleIdentifier] else { return }
        service.destroyTap(tap.handle)
        live[bundleIdentifier] = nil
        guard tap.rebuilds < 1, create(tap.spec, gain: tap.gain, now: now, rebuilds: tap.rebuilds + 1) else {
            failed[bundleIdentifier] = tap.spec
            retryAt[bundleIdentifier] = nil
            return
        }
    }

    /// After sleep, a service restart or a device-wide change: start every tap again from scratch.
    public func rebuildAll(_ snapshot: AudioSnapshot, settings: (String) -> AppVolume?, now: Date) {
        removeAll()
        clearFailures()
        reconcile(snapshot, settings: settings, now: now)
    }

    /// Removes every tap. Every app plays as if MixBar were not running.
    public func removeAll() {
        for tap in live.values { service.destroyTap(tap.handle) }
        live.removeAll()
    }

    /// Lets failed specs be tried again, for when the user opens the mixer.
    public func clearFailures() { failed.removeAll(); retryAt.removeAll() }

    /// Reads every live tap's progress. Learns capture permission from the first sound,
    /// removes a tap that hears only silence while its app plays, and treats IO that
    /// stopped moving as a failure.
    public func checkHealth(_ snapshot: AudioSnapshot, now: Date) {
        for bundle in live.keys.sorted() {
            guard var tap = live[bundle] else { continue }
            let health = service.health(of: tap.handle)
            if health.sawSignal, captureStatus != .granted { setCaptureStatus(.granted) }
            if health.framesRendered != tap.lastFrames {
                tap.lastFrames = health.framesRendered
                tap.lastProgressAt = now
                live[bundle] = tap
            } else if now.timeIntervalSince(tap.lastProgressAt) >= Self.stallTimeout {
                tapFailed(bundle, now: now)
                continue
            }
            if tap.rebuilds > 0, now.timeIntervalSince(tap.createdAt) >= Self.stableAfter {
                tap.rebuilds = 0
                live[bundle] = tap
            }
            // A tap that has heard nothing while its app plays may be silencing the app with
            // nothing to replay (capture refused or revoked). Remove it whatever the learned
            // status, and try again later. Two silent taps in a row without any sound between
            // them mean capture is refused.
            let playing = snapshot.group(bundle)?.isPlaying ?? false
            if !health.sawSignal, playing, now.timeIntervalSince(tap.createdAt) >= Self.permissionTimeout {
                service.destroyTap(tap.handle)
                live[bundle] = nil
                failed[bundle] = tap.spec
                retryAt[bundle] = now.addingTimeInterval(Self.silentRetry)
                setCaptureStatus(captureStatus == .granted ? .unknown : .denied)
            }
        }
    }

    private func setCaptureStatus(_ status: CaptureStatus) {
        guard status != captureStatus else { return }
        captureStatus = status
        onCaptureStatusChange?(status)
    }
}
