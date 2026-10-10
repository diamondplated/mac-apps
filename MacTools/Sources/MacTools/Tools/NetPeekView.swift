import AppKit
import MacToolsCore
import SwiftUI

@MainActor
private final class NetPeekModel: ObservableObject {
    @Published var website = "https://www.apple.com"
    @Published var includeReference = false
    @Published var stages: [NetworkDiagnosticStage] = []
    @Published var running = false
    @Published var message: String?
    @Published var lastRun: Date?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func run() {
        let url: URL
        do { url = try NetworkDiagnostics.validatedURL(website) }
        catch { message = error.localizedDescription; return }
        cancel()
        let runID = UUID(); generation = runID
        stages = []; message = nil; running = true; lastRun = Date()
        let reference = includeReference
        task = Task { [self] in
            do {
                try await NetworkDiagnostics.run(url: url, includeReference: reference) { [weak self] stage in
                    await self?.accept(stage, runID: runID)
                }
                guard generation == runID else { return }
                message = "Check complete. Results describe this moment; network conditions can change."
            } catch is CancellationError {
                guard generation == runID else { return }
                message = "Check cancelled. Completed results are kept below."
            } catch {
                guard generation == runID else { return }
                message = error.localizedDescription
            }
            if generation == runID { running = false; task = nil }
        }
    }

    private func accept(_ stage: NetworkDiagnosticStage, runID: UUID) {
        guard generation == runID, !Task.isCancelled else { return }
        stages.append(stage)
    }

    func cancel() {
        task?.cancel(); task = nil
        generation = UUID()
        if running { message = "Check cancelled. Completed results are kept below." }
        running = false
    }

    func copyReport() {
        let date = lastRun?.formatted(date: .abbreviated, time: .standard) ?? ""
        let report = (["NetPeek · \(date)"] + stages.map { "\($0.title): \($0.state.rawValue)\n\($0.detail)" }).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        message = "Report copied."
    }
}

struct NetPeekView: View {
    @StateObject private var model = NetPeekModel()

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 22) {
                ToolPageHeader(title: "NetPeek", subtitle: "Find where a connection gets stuck.", symbol: "network", tint: .cyan)
                ToolPanel(title: "Check a connection", symbol: "globe") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Website address", text: $model.website, prompt: Text("https://example.com"))
                            .textFieldStyle(.roundedBorder).onSubmit { if !model.running { model.run() } }
                            .disabled(model.running)
                            .accessibilityLabel("Website address to diagnose")
                        Toggle("Also check Apple’s connection reference", isOn: $model.includeReference).disabled(model.running)
                        if model.includeReference {
                            Text(NetworkDiagnostics.referenceURL.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Runs only when you ask. Checks local interfaces, the system route, DNS, and response headers. Requests use no saved cookies or credentials; redirects are not followed.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button { model.run() } label: { Label("Run Diagnostics", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).disabled(model.running)
                            if model.running {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { model.cancel() }
                            }
                            Spacer()
                            Button("Network Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }
                if !model.stages.isEmpty {
                    ToolPanel(title: "Connection report", symbol: "list.bullet.clipboard") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(model.stages) { stage in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: symbol(stage.state)).foregroundStyle(color(stage.state)).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(stage.title).font(.headline)
                                        Text(stage.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer(minLength: 0)
                                }
                                if stage.id != model.stages.last?.id { Divider() }
                            }
                            Button { model.copyReport() } label: { Label("Copy Report", systemImage: "doc.on.doc") }.disabled(model.running)
                        }
                    }
                } else if !model.running {
                    ContentUnavailableView("A clearer picture of your connection", systemImage: "wifi", description: Text("Choose a website and run a short check. No network settings will be changed."))
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }.onDisappear { model.cancel() }
    }

    private func symbol(_ state: NetworkDiagnosticState) -> String {
        switch state { case .passed: "checkmark.circle.fill"; case .attention: "exclamationmark.circle.fill"; case .unavailable: "questionmark.circle" }
    }
    private func color(_ state: NetworkDiagnosticState) -> Color {
        switch state { case .passed: .green; case .attention: .orange; case .unavailable: .secondary }
    }
}
