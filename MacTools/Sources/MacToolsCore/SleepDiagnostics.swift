import AppKit
import Foundation

public struct SleepAssertion: Identifiable, Equatable, Sendable {
    public let id: String
    public let processID: Int32
    public let processName: String
    public let kind: String
    public let detail: String
    public var appURL: URL?
    public var preventsSleep: Bool {
        ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep"].contains(kind)
    }
    public var effect: String {
        switch kind {
        case "PreventUserIdleDisplaySleep": "Keeping the display awake"
        case "PreventSystemSleep": "Requesting that the Mac stay awake"
        case "NoIdleSleepAssertion", "PreventUserIdleSystemSleep": "Preventing automatic sleep"
        case "UserIsActive": "Recent user activity"
        case "BackgroundTask": "Background work"
        default: kind
        }
    }
}

public struct SleepEvent: Identifiable, Equatable, Sendable {
    public var id: String { evidence }
    public let timestamp: String
    public let kind: String
    public let detail: String
    public let evidence: String
    public var title: String {
        switch kind {
        case "DarkWake": "Brief background wake"
        case "Wake": "Mac woke up"
        case "Sleep": "Mac went to sleep"
        default: kind
        }
    }
}

public struct SleepSnapshot: Sendable {
    public let assertions: [SleepAssertion]
    public let events: [SleepEvent]
    public let assertionsAvailable: Bool
    public let warnings: [String]
    public let assertionEvidence: String
    public let wakeEvidence: String
    public let collectedAt: Date
    public var blockers: [SleepAssertion] { assertions.filter(\.preventsSleep) }
    public var evidence: String {
        "SleepPeek — \(collectedAt.formatted())\n\nCurrent sleep requests\n\(assertionEvidence)\n\nRecent sleep and wake events\n\(wakeEvidence)\n\n\(warnings.joined(separator: "\n"))"
    }
}

public enum SleepDiagnostics {
    public static func parseAssertions(_ output: String) -> [SleepAssertion] {
        let pattern = #"^\s*pid\s+(\d+)\((.*?)\):\s*\[([^\]]+)\]\s+\S+\s+(\S+)\s+named:\s*\"(.*)\"\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return output.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let pid = capture(1, match, line).flatMap(Int32.init),
                  let name = capture(2, match, line), let token = capture(3, match, line),
                  let kind = capture(4, match, line), let detail = capture(5, match, line) else { return nil }
            return SleepAssertion(id: "\(pid)-\(token)-\(index)", processID: pid, processName: name,
                                  kind: kind, detail: detail, appURL: nil)
        }
    }

    public static func parseEvents(_ output: String, limit: Int = 40) -> [SleepEvent] {
        guard limit > 0 else { return [] }
        let pattern = #"^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+[+-]\d{4})\s+(DarkWake|Wake|Sleep)\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen: Set<String> = []
        return Array(output.components(separatedBy: .newlines).reversed().compactMap { line -> SleepEvent? in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let timestamp = capture(1, match, line), let kind = capture(2, match, line),
                  let detail = capture(3, match, line), seen.insert(line).inserted else { return nil }
            return SleepEvent(timestamp: timestamp, kind: kind, detail: detail, evidence: line)
        }.prefix(limit))
    }

    private static func capture(_ index: Int, _ match: NSTextCheckingResult, _ line: String) -> String? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    public static func collect() async -> SleepSnapshot {
        var assertions: [SleepAssertion] = []
        var events: [SleepEvent] = []
        var available = false
        var assertionEvidence = "Current sleep requests are unavailable."
        var wakeEvidence = "Recent sleep and wake events are unavailable."
        var warnings: [String] = []
        do {
            let result = try await SystemCommand.run("/usr/bin/pmset", arguments: ["-g", "assertions"], maximumOutputBytes: 256_000)
            assertionEvidence = result.output
            available = result.status == 0 && result.output.contains("Assertion status system-wide:") && !result.truncated
            if available {
                assertions = parseAssertions(result.output)
                let recordedProcesses = result.output.components(separatedBy: .newlines).filter {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid ")
                }.count
                if assertions.count != recordedProcesses {
                    warnings.append("Some sleep requests used an unrecognized format. The evidence below contains the complete response.")
                    available = false
                }
            }
            else { warnings.append("macOS did not return a complete, recognized list of current sleep requests.") }
            if result.output.contains("Kernel Assertions:") { warnings.append("Hardware or kernel sleep requests are also present. See the evidence for details.") }
        } catch { warnings.append("Couldn’t read sleep requests: \(error.localizedDescription)") }
        do {
            let result = try await SystemCommand.run("/usr/bin/pmset", arguments: ["-g", "log"], timeout: 15,
                                                     maximumOutputBytes: 128_000, retainOutputTail: true)
            if result.status == 0 {
                events = parseEvents(result.output)
                wakeEvidence = events.map(\.evidence).joined(separator: "\n")
                if result.truncated { warnings.append("Showing events from the newest portion of the power history.") }
                if events.isEmpty { warnings.append("No sleep or wake events were found in the available recent history. macOS may not record a specific wake reason.") }
            } else { warnings.append("macOS did not provide recent power history.") }
        } catch { warnings.append("Couldn’t read recent wake history: \(error.localizedDescription)") }
        let applications = await MainActor.run {
            Dictionary(NSWorkspace.shared.runningApplications.compactMap { app -> (Int32, URL)? in
                guard let url = app.bundleURL else { return nil }; return (app.processIdentifier, url)
            }, uniquingKeysWith: { first, _ in first })
        }
        assertions = assertions.map { item in
            var item = item
            item.appURL = applications[item.processID]
            return item
        }
        return SleepSnapshot(assertions: assertions, events: events, assertionsAvailable: available, warnings: warnings,
                             assertionEvidence: assertionEvidence, wakeEvidence: wakeEvidence, collectedAt: Date())
    }
}
