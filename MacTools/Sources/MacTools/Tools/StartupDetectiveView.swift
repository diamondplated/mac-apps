import AppKit
import MacToolsCore
import SwiftUI

struct StartupDetectiveView: View {
    @State private var snapshot: StartupSnapshot?
    @State private var isRefreshing = false
    @State private var search = ""
    @State private var onlyMissing = false
    @State private var visibleCount = 60
    @State private var copied = false
    @AppStorage("startupDetective.showAppleServices") private var showAppleServices = false

    private var entries: [StartupEntry] {
        (snapshot?.entries ?? []).filter {
            (showAppleServices || !$0.fileURL.path.hasPrefix("/System/Library/")) &&
            (!onlyMissing || $0.targetStatus == .missing) &&
            (search.isEmpty || "\($0.displayName) \($0.label) \($0.executable ?? "") \($0.origin)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ToolPageHeader(title: "Startup Detective", subtitle: "Find the apps and services that start with your Mac.", symbol: "power.circle.fill", tint: .orange)
            HStack {
                Button { Task { await refresh() } } label: {
                    Label(isRefreshing ? "Inspecting…" : "Refresh", systemImage: "arrow.clockwise")
                }.disabled(isRefreshing)
                Button("Open Login Items", systemImage: "gearshape") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                if let snapshot {
                    Button(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snapshot.evidence, forType: .string)
                        copied = true
                    }
                }
            }
            ToolPanel(title: "What starts in the background", symbol: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("These are installed startup definitions. Their presence doesn’t mean they are enabled or running. Login Items in System Settings shows the controls macOS makes available.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        Text("\(entries.count) matching services").font(.headline)
                        Spacer()
                        Toggle("Include macOS services", isOn: $showAppleServices).toggleStyle(.checkbox)
                    }
                    HStack {
                        TextField("Search app, service, or path", text: $search)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Search startup services")
                        Toggle("Missing targets", isOn: $onlyMissing).toggleStyle(.checkbox)
                    }
                    if isRefreshing && snapshot == nil {
                        ProgressView("Inspecting startup services…").padding(.vertical, 20)
                    } else if snapshot != nil && entries.isEmpty {
                        ContentUnavailableView("No matching services", systemImage: "checkmark.circle", description: Text("Try changing your search or filters."))
                    }
                    ForEach(Array(entries.prefix(visibleCount))) { entry in
                        Divider()
                        startupRow(entry)
                    }
                    if entries.count > visibleCount {
                        Button("Show 60 more") { visibleCount += 60 }
                    }
                }
            }
            if let snapshot {
                if !snapshot.warnings.isEmpty {
                    ToolPanel(title: "Inspection notes", symbol: "info.circle") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ToolPanel(title: "Background registrations", symbol: "app.badge") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("macOS also tracks modern login items and background helpers separately. The system’s registration list is included here when available.").foregroundStyle(.secondary)
                        DisclosureGroup("View registration evidence") {
                            ScrollView([.horizontal, .vertical]) {
                                Text(snapshot.backgroundEvidence).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 240).padding(.top, 8)
                        }
                    }
                }
                Text("Inspected \(snapshot.collectedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { if snapshot == nil { await refresh() } }
        .onChange(of: search) { _, _ in visibleCount = 60 }
        .onChange(of: onlyMissing) { _, _ in visibleCount = 60 }
        .onChange(of: showAppleServices) { _, _ in visibleCount = 60 }
    }

    private func startupRow(_ entry: StartupEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.appURL == nil ? "gearshape.2" : "app")
                .font(.title2).foregroundStyle(entry.targetStatus == .missing ? Color.orange : Color.secondary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.displayName).font(.headline).textSelection(.enabled)
                    if entry.targetStatus == .missing {
                        Label("Target missing", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                if entry.displayName != entry.label { Text(entry.label).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text(entry.origin).font(.caption).foregroundStyle(.secondary)
                if let executable = entry.executable {
                    Text(executable).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2).help(executable)
                }
                if entry.targetStatus == .unresolved {
                    Text("The executable’s location cannot be determined from this definition.").font(.caption).foregroundStyle(.secondary)
                }
                if entry.targetStatus == .missing {
                    Text("The declared executable is absent. It may be left over from an uninstalled app or live on a disconnected volume.").font(.caption).foregroundStyle(.secondary)
                }
                if entry.declaredDisabled {
                    Text("Marked disabled in its definition; macOS may have a separate override.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button("Reveal Service File") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
                if let app = entry.appURL, FileManager.default.fileExists(atPath: app.path) {
                    Button("Reveal Parent App") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                }
                Button("Copy Service Path") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.fileURL.path, forType: .string)
                }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(entry.displayName)")
        }.padding(.vertical, 5)
    }

    @MainActor private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        copied = false
        snapshot = await StartupDiagnostics.collect()
        isRefreshing = false
    }
}
