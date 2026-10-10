import AppKit
import CryptoKit
import SwiftUI
import MacToolsCore

@MainActor
final class SpaceWatchModel: ObservableObject {
    @Published var folder: URL?
    @Published var snapshot: StorageSnapshot?
    @Published var previous: StorageSnapshot?
    @Published var selection = Set<String>()
    @Published var scanning = false
    @Published var recycling = false
    @Published var error: String?
    private var worker: Task<StorageSnapshot, Error>?
    private var operation: Task<Void, Never>?

    private var baselineDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Tools/Storage Baselines", isDirectory: true)
    }

    private func baselineURL(_ folder: URL) -> URL {
        let name = SHA256.hash(data: Data(folder.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return baselineDirectory.appendingPathComponent(name + ".json")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan Folder"
        panel.message = "Choose a local folder to measure. Cloud-only items and app packages are skipped."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        folder = chosen
        snapshot = nil
        previous = nil
        selection.removeAll()
        scan()
    }

    func scan() {
        guard let folder, !scanning, !recycling else { return }
        error = nil
        selection.removeAll()
        if let data = try? Data(contentsOf: baselineURL(folder)) {
            previous = try? JSONDecoder().decode(StorageSnapshot.self, from: data)
        }
        scanning = true
        let worker = Task.detached(priority: .utility) { try StorageDiagnostics.scan(root: folder) }
        self.worker = worker
        operation = Task { [weak self] in
            do {
                let result = try await worker.value
                guard let self else { return }
                self.snapshot = result
                if result.isComplete {
                    do {
                        try FileManager.default.createDirectory(at: self.baselineDirectory, withIntermediateDirectories: true,
                                                                attributes: [.posixPermissions: 0o700])
                        try JSONEncoder().encode(result).write(to: self.baselineURL(folder), options: [.atomic])
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.baselineURL(folder).path)
                    } catch { self.error = "Scan finished, but the baseline could not be saved: \(error.localizedDescription)" }
                }
            } catch is CancellationError {
                self?.error = "Scan canceled. The previous completed measurement was kept."
            } catch { self?.error = error.localizedDescription }
            self?.scanning = false
            self?.worker = nil
        }
    }

    func cancel() { worker?.cancel() }

    var selectedFiles: [StorageFile] { snapshot?.largestFiles.filter { selection.contains($0.id) } ?? [] }

    func recycleSelected() {
        guard let snapshot, !scanning, !recycling else { return }
        do {
            let urls = try StorageDiagnostics.validatedTrashURLs(files: selectedFiles, snapshot: snapshot)
            guard !urls.isEmpty else { return }
            recycling = true
            NSWorkspace.shared.recycle(urls) { [weak self] _, failure in
                let message = failure?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    self.recycling = false
                    self.selection.removeAll()
                    if let message { self.error = "Some files could not be moved to Trash: \(message). Scan again to refresh the list." }
                    else { self.scan() }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct SpaceWatchView: View {
    @StateObject private var model = SpaceWatchModel()
    @State private var reviewing = false
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 20) {
                ToolPageHeader(title: "SpaceWatch", subtitle: "See what is taking space, and what has grown since your last scan.", symbol: "internaldrive", tint: .orange)
                ToolPanel(title: "Measure a folder", symbol: "folder") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.folder?.lastPathComponent ?? "Choose where to look").font(.headline)
                                Text(model.folder?.path ?? "Downloads, a project folder, or another local folder")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Choose Folder…", action: model.chooseFolder).disabled(model.scanning || model.recycling)
                            if model.scanning {
                                ProgressView().controlSize(.small)
                                Button("Cancel", action: model.cancel)
                            } else if model.folder != nil {
                                Button("Scan Again", action: model.scan).disabled(model.recycling)
                            }
                        }
                        Text("Counts space allocated on disk. Skips cloud items, symbolic links, other volumes, and app packages. Scans stop after 50,000 entries or 30 seconds.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if let snapshot = model.snapshot {
                    HStack(alignment: .top, spacing: 16) {
                        metric("Space measured", value: bytes(snapshot.allocatedBytes), detail: "\(snapshot.fileCount.formatted()) files • \(bytes(snapshot.logicalBytes)) logical size")
                        if let previous = model.previous, let growth = snapshot.growth(since: previous) {
                            metric("Since last scan", value: "\(growth > 0 ? "+" : growth < 0 ? "−" : "")\(bytes(abs(growth)))", detail: previous.completedAt.formatted(date: .abbreviated, time: .shortened))
                        } else {
                            metric("Growth tracking", value: "\(snapshot.isComplete ? "Baseline saved" : "Partial scan")", detail: "Compare after the next complete scan of this folder")
                        }
                    }
                    if snapshot.wasLimited || snapshot.unreadableCount > 0 || snapshot.skippedCount > 0 {
                        Label("\(snapshot.wasLimited ? "Scan limit reached. " : "")\(snapshot.unreadableCount) unreadable; \(snapshot.skippedCount) skipped. Totals cover measured files only.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ToolPanel(title: "Inside this folder", symbol: "chart.bar.xaxis") {
                        VStack(spacing: 10) {
                            ForEach(Array(snapshot.folders.prefix(12))) { folder in
                                HStack {
                                    Text(folder.name).lineLimit(1)
                                    Spacer()
                                    Text(bytes(folder.allocatedBytes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            if snapshot.folders.isEmpty { Text("No local files were measured.").foregroundStyle(.secondary) }
                        }
                    }
                    ToolPanel(title: "Largest files", symbol: "doc.text.magnifyingglass") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Review up to 200 largest files. Nothing is removed automatically.").font(.caption).foregroundStyle(.secondary)
                            ForEach(snapshot.largestFiles) { file in
                                HStack(spacing: 10) {
                                    Toggle(isOn: Binding(get: { model.selection.contains(file.id) }, set: { selected in
                                        if selected { model.selection.insert(file.id) } else { model.selection.remove(file.id) }
                                    })) { Text(file.relativePath).lineLimit(1).truncationMode(.middle) }
                                    .toggleStyle(.checkbox).disabled(model.scanning || model.recycling)
                                    Spacer(minLength: 12)
                                    Text(bytes(file.allocatedBytes)).monospacedDigit().foregroundStyle(.secondary)
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: snapshot.rootPath).appendingPathComponent(file.relativePath)])
                                    } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Reveal in Finder")
                                }
                                Divider()
                            }
                            HStack {
                                Text("\(model.selection.count) selected").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Review Selected Files…") { reviewing = true }
                                    .disabled(model.selection.isEmpty || model.scanning || model.recycling)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $reviewing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Move \(model.selectedFiles.count) \(model.selectedFiles.count == 1 ? "file" : "files") to Trash?").font(.title2.bold())
                Text("Review every selected file. You can restore files from Trash in Finder. Changed files, symbolic links, and System or Library files will be refused.").foregroundStyle(.secondary)
                List(model.selectedFiles) { file in
                    HStack { Text(file.relativePath); Spacer(); Text(bytes(file.allocatedBytes)).foregroundStyle(.secondary) }
                }.frame(minHeight: 180, maxHeight: 360)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { reviewing = false }
                    Button("Move to Trash", role: .destructive) { reviewing = false; model.recycleSelected() }
                }
            }.padding(24).frame(width: 620)
        }
        .onDisappear { model.cancel() }
    }

    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.bold()).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}
