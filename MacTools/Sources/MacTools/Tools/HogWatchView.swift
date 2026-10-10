import AppKit
import MacToolsCore
import SwiftUI

private struct WatchedProcess: Identifiable {
    var sample: ProcessSample
    var appName: String?
    var bundleID: String?
    var appURL: URL?
    var icon: NSImage?
    var id: ProcessIdentity { sample.identity }
    var name: String { appName ?? URL(fileURLWithPath: sample.identity.executable).lastPathComponent }
    var canQuit: Bool {
        appURL != nil && bundleID != nil && sample.identity.launchDate != nil &&
        sample.identity.uid == getuid() && sample.identity.pid != ProcessInfo.processInfo.processIdentifier
    }
}

@MainActor
private final class HogWatchModel: ObservableObject {
    @Published var processes: [WatchedProcess] = []
    @Published var sustained = Set<ProcessIdentity>()
    @Published var lastSample: Date?
    @Published var isSampling = false
    @Published var error: String?
    @Published var notice: String?
    private var tracker = SustainedCPUTracker()

    func resetWatch() { tracker.reset(); sustained.removeAll() }

    func sample(threshold: Double, interval: Double) async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }
        do {
            let result = try await SystemCommand.run("/bin/ps", arguments: ["-axo", "pid=,uid=,pcpu=,rss=,comm="], timeout: 8, maximumOutputBytes: 2_000_000)
            try Task.checkCancellation()
            guard result.status == 0, !result.truncated else {
                throw NSError(domain: "HogWatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS couldn’t provide a complete process sample. Try again or open Activity Monitor."])
            }
            let samples = ProcessDiagnostics.parse(result.output).map { raw in
                var sample = raw
                sample.identity.launchDate = ProcessDiagnostics.startedAt(pid: sample.identity.pid)
                return sample
            }
            guard !samples.isEmpty else {
                throw NSError(domain: "HogWatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "No readable processes were returned. Open Activity Monitor to inspect this Mac."])
            }
            let now = Date()
            sustained = tracker.observe(samples, at: now, threshold: threshold, interval: interval)
            processes = samples.map { sample in
                let app = NSRunningApplication(processIdentifier: sample.identity.pid)
                // Attribute only a matching executable; helpers retain their own process name.
                let matches = app?.executableURL?.standardizedFileURL.path == URL(fileURLWithPath: sample.identity.executable).standardizedFileURL.path
                return WatchedProcess(sample: sample, appName: matches ? app?.localizedName : nil,
                                      bundleID: matches ? app?.bundleIdentifier : nil,
                                      appURL: matches ? app?.bundleURL : nil, icon: matches ? app?.icon : nil)
            }
            lastSample = now
            error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; resetWatch() }
    }

    func quit(_ process: WatchedProcess) async {
        guard let bundleID = process.bundleID, let originalURL = process.appURL else { return }
        do {
            let result = try await SystemCommand.run("/bin/ps", arguments: ["-p", String(process.sample.identity.pid), "-o", "pid=,uid=,pcpu=,rss=,comm="], timeout: 5)
            guard result.status == 0, !result.truncated,
                  var current = ProcessDiagnostics.parse(result.output).first,
                  let app = NSRunningApplication(processIdentifier: process.sample.identity.pid),
                  !app.isTerminated, app.bundleURL?.standardizedFileURL == originalURL.standardizedFileURL,
                  app.executableURL?.standardizedFileURL.path == current.identity.executable else {
                notice = "This app has changed or already quit. Refresh before trying again."; return
            }
            current.identity.launchDate = ProcessDiagnostics.startedAt(pid: current.identity.pid)
            guard ProcessDiagnostics.canQuit(expected: process.sample.identity, current: current.identity,
                                             expectedBundleID: bundleID, currentBundleID: app.bundleIdentifier,
                                             currentUID: getuid(), ownPID: ProcessInfo.processInfo.processIdentifier) else {
                notice = "This app’s identity changed. Refresh before trying again."; return
            }
            notice = app.terminate() ? "Asked \(process.name) to quit. It may ask you to save your work." : "\(process.name) declined the quit request. Open the app to finish or save your work."
        } catch { self.error = error.localizedDescription }
    }
}

struct HogWatchView: View {
    @StateObject private var model = HogWatchModel()
    @AppStorage("hogWatch.watchEnabled") private var watching = false
    @AppStorage("hogWatch.sampleInterval") private var storedInterval = 5.0
    @AppStorage("hogWatch.cpuThreshold") private var storedThreshold = 50.0
    @State private var sortByMemory = false
    @State private var search = ""
    @State private var quitTarget: WatchedProcess?
    private var interval: Double { [3.0, 5.0, 10.0, 30.0].contains(storedInterval) ? storedInterval : 5 }
    private var threshold: Double { storedThreshold.isFinite ? min(400, max(10, storedThreshold)) : 50 }
    private var watchKey: String { "\(watching)-\(interval)-\(threshold)" }
    private var sorted: [WatchedProcess] {
        model.processes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || String($0.sample.identity.pid).contains(search) }
            .sorted {
                let lhs = sortByMemory ? Double($0.sample.residentBytes) : $0.sample.cpuPercent
                let rhs = sortByMemory ? Double($1.sample.residentBytes) : $1.sample.cpuPercent
                return lhs == rhs ? $0.sample.identity.pid < $1.sample.identity.pid : lhs > rhs
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ToolPageHeader(title: "HogWatch", subtitle: "Find persistent CPU activity and see which processes use memory.", symbol: "waveform.path.ecg", tint: .orange)
            ToolPanel(title: "Observe your Mac", symbol: "gauge.with.dots.needle.67percent") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Toggle("Watch while this page is open", isOn: $watching)
                        Spacer()
                        Button { Task { await model.sample(threshold: threshold, interval: interval) } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }.disabled(model.isSampling)
                    }
                    HStack {
                        Picker("Sample every", selection: $storedInterval) {
                            Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0)
                            Text("10 seconds").tag(10.0); Text("30 seconds").tag(30.0)
                        }.frame(maxWidth: 240)
                        Spacer()
                        Stepper("CPU threshold: \(Int(threshold))%", value: $storedThreshold, in: 10...400, step: 10)
                            .frame(maxWidth: 250)
                    }
                    Text("Persistent activity means at least three high readings over \(Int(interval * 2)) seconds. Watching pauses when you leave this page; history starts fresh when you return.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Circle().fill(watching ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(model.isSampling ? "Reading processes…" : watching ? "Watching every \(Int(interval)) seconds" : "Watching is off · refresh for a snapshot")
                        Spacer()
                        if let date = model.lastSample { Text(date, style: .time).monospacedDigit() }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            ToolPanel(title: "Resource use", symbol: "cpu") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        TextField("Filter by app, process, or PID", text: $search).textFieldStyle(.roundedBorder)
                        Picker("Sort", selection: $sortByMemory) {
                            Text("CPU").tag(false); Text("Memory").tag(true)
                        }.pickerStyle(.segmented).frame(width: 165)
                    }
                    if model.lastSample == nil {
                        ContentUnavailableView("No sample yet", systemImage: "waveform.path.ecg", description: Text("Refresh to see current process activity."))
                    } else if sorted.isEmpty {
                        Text("No processes match this filter.").foregroundStyle(.secondary).padding(.vertical, 20)
                    } else {
                        HStack {
                            Text("Process"); Spacer(); Text("CPU").frame(width: 70, alignment: .trailing)
                            Text("Memory").frame(width: 85, alignment: .trailing); Color.clear.frame(width: 45, height: 1)
                        }.font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(sorted.prefix(75))) { process in
                            HStack(spacing: 10) {
                                if let icon = process.icon {
                                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 28, height: 28)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(process.name).fontWeight(.medium).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text("PID \(process.sample.identity.pid)")
                                        if model.sustained.contains(process.id) { Text("· Persistent CPU").foregroundStyle(.orange) }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Text(process.sample.cpuPercent, format: .number.precision(.fractionLength(1)))
                                    .monospacedDigit().frame(width: 70, alignment: .trailing)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: process.sample.residentBytes), countStyle: .memory))
                                    .monospacedDigit().frame(width: 85, alignment: .trailing)
                                Button("Quit") { quitTarget = process }.disabled(!process.canQuit)
                                    .help(process.canQuit ? "Ask this app to quit normally" : "Quit is available for your identified apps")
                                    .frame(width: 45)
                            }.padding(.vertical, 4)
                            Divider()
                        }
                        if sorted.count > 75 { Text("Showing the top 75 of \(sorted.count) processes. Filter to narrow the list.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("CPU is macOS’s recent process usage estimate; 100% represents one CPU core. Memory is resident RAM, which can include shared pages. Persistent activity requires a readable process start time. These readings do not measure energy use or temperature.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.lastSample != nil && model.sustained.isEmpty {
                        Text("No persistent CPU activity observed in this watch session.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Open Activity Monitor", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                }
            }
        }
        .task(id: watchKey) {
            model.resetWatch()
            repeat {
                await model.sample(threshold: threshold, interval: interval)
                guard watching, !Task.isCancelled else { break }
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
            } while !Task.isCancelled
        }
        .confirmationDialog("Ask \(quitTarget?.name ?? "this app") to quit?", isPresented: Binding(
            get: { quitTarget != nil }, set: { if !$0 { quitTarget = nil } }
        ), titleVisibility: .visible) {
            Button("Quit App") { if let process = quitTarget { quitTarget = nil; Task { await model.quit(process) } } }
            Button("Cancel", role: .cancel) { quitTarget = nil }
        } message: { Text("The app can ask you to save changes or decline. HogWatch will check that it is still the same app before requesting a normal quit.") }
    }
}
