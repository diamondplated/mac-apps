import Foundation

/// Running processes from the keep-awake list, keyed by process so a second copy
/// of an app quitting does not end the reason while the first still runs.
public struct RunningApps: Equatable {
    public private(set) var byProcess: [Int32: (bundleIdentifier: String, name: String)] = [:]
    public init() {}

    public static func == (lhs: RunningApps, rhs: RunningApps) -> Bool {
        lhs.byProcess.mapValues { $0.bundleIdentifier + "\u{0}" + $0.name } == rhs.byProcess.mapValues { $0.bundleIdentifier + "\u{0}" + $0.name }
    }

    public mutating func launched(pid: Int32, bundleIdentifier: String?, name: String?) {
        guard let bundleIdentifier else { return }
        byProcess[pid] = (bundleIdentifier, name ?? bundleIdentifier)
    }

    public mutating func terminated(pid: Int32) { byProcess[pid] = nil }

    /// Names of the listed apps that are running, in list order, one per app.
    public func runningNames(from list: [String]) -> [String] {
        list.compactMap { identifier in
            byProcess.filter { $0.value.bundleIdentifier == identifier }.min { $0.key < $1.key }?.value.name
        }
    }
}

public struct PowerSource: Equatable {
    public var onBattery: Bool
    /// Battery charge, 0–100; nil on a Mac without a battery.
    public var percent: Int?
    public init(onBattery: Bool, percent: Int?) { self.onBattery = onBattery; self.percent = percent }
    public static let mains = PowerSource(onBattery: false, percent: nil)

    public static let cutoffPercent = 20
    /// Timed and manual keep-awake end themselves on battery below 20 percent.
    public var endsUserKeepAwake: Bool {
        guard onBattery, let percent else { return false }
        return percent < Self.cutoffPercent
    }
}

public enum AwakeReason: Equatable {
    case manual
    case timed(until: Date)
    case apps([String])
}

/// Everything that can keep the Mac awake, combined into one answer.
public struct KeepAwakeState: Equatable {
    /// "Until I Turn It Off".
    public var manual = false
    /// A "Keep Awake For" timer; nil when none is running.
    public var until: Date?
    public var apps: [String] = []
    public var running = RunningApps()
    /// Set when the battery cut-off ended a manual or timed keep-awake; cleared when the user turns it on again.
    public var endedForLowBattery = false
    public init() {}

    /// Whether a manual or timed keep-awake is on at this moment.
    public func userKeepAwakeIsOn(at now: Date) -> Bool {
        manual || (until.map { $0 > now } ?? false)
    }

    /// Drops an expired timer and, on low battery, ends manual and timed keep-awake.
    /// Returns true when the low-battery cut-off ended something, so the caller can
    /// persist the manual switch.
    @discardableResult
    public mutating func settle(at now: Date, power: PowerSource) -> Bool {
        if let until, until <= now { self.until = nil }
        // The notice lasts until the Mac is plugged in again.
        if !power.onBattery { endedForLowBattery = false }
        guard power.endsUserKeepAwake, manual || until != nil else { return false }
        manual = false
        until = nil
        endedForLowBattery = true
        return true
    }

    /// The reason shown first: the manual switch, then a timer, then the app list.
    public func reason(at now: Date) -> AwakeReason? {
        if manual { return .manual }
        if let until, until > now { return .timed(until: until) }
        let names = running.runningNames(from: apps)
        return names.isEmpty ? nil : .apps(names)
    }

    public func shouldBeAwake(at now: Date) -> Bool { reason(at: now) != nil }

    /// The next moment the answer can change on its own (a timer ending).
    public func nextDeadline(after now: Date) -> Date? {
        guard !manual, let until, until > now else { return nil }
        return until
    }

    public mutating func turnOnManually() { manual = true; until = nil; endedForLowBattery = false }
    public mutating func keepAwake(for duration: TimeInterval, from now: Date) {
        manual = false; until = now.addingTimeInterval(duration); endedForLowBattery = false
    }
    public mutating func turnOffUserKeepAwake() { manual = false; until = nil; endedForLowBattery = false }
}

/// The one sentence the menu's first line and the bridge's `awakeReason` share.
public enum AwakeSentence {
    public static func sentence(for reason: AwakeReason?, now: Date, timeFormatter: DateFormatter = defaultTimeFormatter) -> String? {
        guard let reason else { return nil }
        switch reason {
        case .manual:
            return "Awake until you turn it off"
        case .timed(let until):
            let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
            if minutes < 60 { return "Awake for \(minutes) more \(minutes == 1 ? "minute" : "minutes")" }
            return "Awake until \(timeFormatter.string(from: until))"
        case .apps(let names):
            switch names.count {
            case 0: return nil
            case 1: return "Awake while \(names[0]) is running"
            case 2: return "Awake while \(names[0]) and \(names[1]) are running"
            default: return "Awake while \(names[0]) and \(names.count - 1) other apps are running"
            }
        }
    }

    /// The first line when nothing keeps the Mac awake.
    public static func idleTitle(endedForLowBattery: Bool) -> String {
        endedForLowBattery ? "Keep Awake Ended at Low Battery" : "Not Keeping Awake"
    }

    public static var defaultTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }
}

public enum AssertionKind: Equatable {
    /// Idle system sleep is prevented; the display may still sleep.
    case system
    /// The display stays on too (which also keeps the system awake).
    case display
}

/// IOKit power management, injected so the bookkeeping is tested without holding a real assertion.
public protocol PowerService: AnyObject {
    func takeAssertion(_ kind: AssertionKind, reason: String) -> UInt32?
    func releaseAssertion(_ id: UInt32)
}

/// Holds at most one assertion, only while a reason is active.
public final class AssertionKeeper {
    private let service: PowerService
    public private(set) var held: (kind: AssertionKind, id: UInt32)?
    public init(service: PowerService) { self.service = service }

    /// `desired` nil releases; a different kind takes the new one before releasing the old so the Mac never dips.
    /// If the new one cannot be taken, the old one is kept and the next update tries again.
    public func update(_ desired: AssertionKind?, reason: String = "Keeping this Mac awake") {
        guard held?.kind != desired else { return }
        let previous = held
        if let desired {
            guard let id = service.takeAssertion(desired, reason: reason) else { return }
            held = (desired, id)
        } else {
            held = nil
        }
        if let previous { service.releaseAssertion(previous.id) }
    }

    public func releaseAll() { update(nil) }

    deinit { if let held { service.releaseAssertion(held.id) } }
}
