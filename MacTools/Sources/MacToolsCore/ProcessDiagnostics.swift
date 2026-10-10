import Foundation
import Darwin

public struct ProcessIdentity: Hashable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var executable: String
    public var launchDate: Date?

    public init(pid: Int32, uid: UInt32, executable: String, launchDate: Date? = nil) {
        self.pid = pid; self.uid = uid; self.executable = executable; self.launchDate = launchDate
    }
}

public struct ProcessSample: Identifiable, Sendable {
    public var identity: ProcessIdentity
    public var cpuPercent: Double
    public var residentBytes: UInt64
    public var id: ProcessIdentity { identity }

    public init(identity: ProcessIdentity, cpuPercent: Double, residentBytes: UInt64) {
        self.identity = identity; self.cpuPercent = cpuPercent; self.residentBytes = residentBytes
    }
}

public enum ProcessDiagnostics {
    /// Kernel birth time distinguishes reused PIDs without reading command arguments.
    public static func startedAt(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
    /// `ps -axo pid=,uid=,pcpu=,rss=,comm=`. Never request args or environment.
    public static func parse(_ output: String) -> [ProcessSample] {
        var seen = Set<Int32>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard columns.count == 5,
                  let pid = Int32(columns[0]), pid > 0,
                  let uid = UInt32(columns[1]),
                  let cpu = Double(columns[2]), cpu.isFinite, cpu >= 0,
                  let rss = UInt64(columns[3]), rss <= UInt64.max / 1024,
                  !columns[4].isEmpty, seen.insert(pid).inserted else { return nil }
            return ProcessSample(identity: .init(pid: pid, uid: uid, executable: String(columns[4])),
                                 cpuPercent: cpu, residentBytes: rss * 1024)
        }
    }

    /// Both snapshots must name the same live app generation owned by the current user.
    public static func canQuit(expected: ProcessIdentity, current: ProcessIdentity,
                               expectedBundleID: String, currentBundleID: String?,
                               currentUID: UInt32, ownPID: Int32) -> Bool {
        expected.pid != ownPID && expected.uid == currentUID && expected == current &&
        expected.launchDate != nil && !expectedBundleID.isEmpty && expectedBundleID == currentBundleID
    }
}

/// Bounded history: one streak per currently observed process, discarded when absent.
public struct SustainedCPUTracker: Sendable {
    private struct Streak: Sendable { var began: Date; var latest: Date; var count: Int }
    private var streaks: [ProcessIdentity: Streak] = [:]
    public init() {}
    public mutating func reset() { streaks.removeAll() }

    public mutating func observe(_ samples: [ProcessSample], at date: Date, threshold: Double,
                                 interval: TimeInterval) -> Set<ProcessIdentity> {
        let interval = max(1, interval)
        var next: [ProcessIdentity: Streak] = [:]
        var sustained = Set<ProcessIdentity>()
        for sample in samples where sample.cpuPercent >= threshold && sample.identity.launchDate != nil {
            var streak = streaks[sample.identity] ?? Streak(began: date, latest: date, count: 0)
            let gap = date.timeIntervalSince(streak.latest)
            if gap < 0 || gap > interval * 2.5 { streak = Streak(began: date, latest: date, count: 0) }
            // Repeated manual refreshes cannot turn one instant into sustained usage.
            if streak.count == 0 || gap >= interval * 0.8 { streak.count += 1; streak.latest = date }
            next[sample.identity] = streak
            if streak.count >= 3 && date.timeIntervalSince(streak.began) >= interval * 2 {
                sustained.insert(sample.identity)
            }
        }
        streaks = next
        return sustained
    }
}
