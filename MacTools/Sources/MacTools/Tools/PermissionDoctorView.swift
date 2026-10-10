import AppKit
import MacToolsCore
import SwiftUI

struct PermissionDoctorView: View {
    @ObservedObject var library: LibraryModel
    @State private var reports: [PermissionReport] = []
    @State private var scanning = false
    @State private var checkingName = ""
    @State private var checkedAt: Date?
    @State private var operationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ToolPageHeader(title: "Permission Doctor", subtitle: "Find the right app copy, check its signature, and review the access it needs.", symbol: "stethoscope", tint: .teal)
            ToolPanel(title: "Check your tools", symbol: "checkmark.shield") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Permission results come from each tool’s own diagnostics. When a tool cannot report its access, check its entry in System Settings and try the feature.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button("Run Checks", systemImage: "arrow.clockwise") { Task { await refresh() } }
                            .buttonStyle(.borderedProminent).disabled(scanning || library.isBusy)
                        if scanning { ProgressView().controlSize(.small); Text("Checking \(checkingName)…").font(.caption) }
                        else if let checkedAt { Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let operationError {
                Label(operationError, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
            }
            ForEach(reports) { report in
                ToolPanel(title: report.app.name, symbol: report.app.symbolName) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(report.checks) { finding($0) }
                        if !report.installations.isEmpty {
                            paths("Installed copies", values: report.installations)
                        }
                        if !report.runningURLs.isEmpty {
                            paths("Running from", values: report.runningURLs)
                        }
                        Divider()
                        if report.permissions.isEmpty {
                            Label("This tool does not require Screen Recording, Accessibility, or Input Monitoring access.", systemImage: "lock.open")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(report.permissions) { finding($0) }
                        }
                        HStack(spacing: 12) {
                            Button(report.isRunning ? "Restart \(report.app.name)" : "Open \(report.app.name)") {
                                Task { await openOrRestart(report) }
                            }.disabled(!report.canOpen || scanning || library.isBusy)
                            if report.isRunning {
                                Button("Quit \(report.app.name)") { Task { await quit(report.app) } }
                                    .disabled(scanning || library.isBusy)
                            }
                        }
                        Text("After changing permissions, restart the affected tool and try its feature again. Your settings are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { if reports.isEmpty { await refresh() } }
    }

    @ViewBuilder private func finding(_ value: PermissionFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(value.status)).foregroundStyle(color(value.status)).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(value.title).font(.headline)
                    Spacer(minLength: 8)
                    Text(value.status.label).font(.caption).foregroundStyle(color(value.status))
                }
                Text(value.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let pane = value.settingsPane {
                    Button("Open \(value.title) Settings") { library.openSettings(pane) }
                        .font(.callout)
                }
            }
        }
    }

    private func paths(_ title: String, values: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(values, id: \.path) { url in
                HStack(alignment: .top) {
                    Text(url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 6)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .font(.caption)
                }
            }
        }
    }

    private func symbol(_ status: DiagnosticStatus) -> String {
        switch status { case .passed: "checkmark.circle.fill"; case .attention: "exclamationmark.circle.fill"; case .notChecked: "questionmark.circle" }
    }

    private func color(_ status: DiagnosticStatus) -> Color {
        switch status { case .passed: .green; case .attention: .orange; case .notChecked: .secondary }
    }

    @MainActor private func refresh(clearError: Bool = true) async {
        guard !scanning, !library.isBusy else { return }
        scanning = true
        if clearError { operationError = nil }
        library.operation = "Checking tools…"
        defer { scanning = false; library.operation = nil }
        var values: [PermissionReport] = []
        for app in ManagedApp.allCases {
            guard !Task.isCancelled else { return }
            checkingName = app.name
            library.operation = "Checking \(app.name)…"
            values.append(await PermissionDiagnostics.inspect(app, manager: library.manager))
        }
        guard !Task.isCancelled else { return }
        reports = values
        checkedAt = Date()
    }

    @MainActor private func openOrRestart(_ report: PermissionReport) async {
        guard !library.isBusy, !scanning else { return }
        operationError = nil
        library.operation = report.isRunning ? "Restarting \(report.app.name)…" : "Opening \(report.app.name)…"
        do {
            if report.isRunning { try await library.manager.quit(report.app) }
            try await library.manager.launch(report.app)
        } catch { operationError = error.localizedDescription }
        library.operation = nil
        await library.refresh()
        await refresh(clearError: false)
    }

    @MainActor private func quit(_ app: ManagedApp) async {
        guard !library.isBusy, !scanning else { return }
        operationError = nil
        library.operation = "Quitting \(app.name)…"
        do { try await library.manager.quit(app) }
        catch { operationError = error.localizedDescription }
        library.operation = nil
        await library.refresh()
        await refresh(clearError: false)
    }
}
