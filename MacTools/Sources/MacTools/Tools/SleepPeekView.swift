import AppKit
import MacToolsCore
import SwiftUI

struct SleepPeekView: View {
    @State private var snapshot: SleepSnapshot?
    @State private var isRefreshing = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ToolPageHeader(title: "SleepPeek", subtitle: "See what’s keeping your Mac awake, and what woke it recently.", symbol: "moon.zzz.fill", tint: .indigo)
            HStack {
                Button { Task { await refresh() } } label: {
                    Label(isRefreshing ? "Inspecting…" : "Refresh", systemImage: "arrow.clockwise")
                }.disabled(isRefreshing)
                Spacer()
                if let snapshot {
                    Button(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snapshot.evidence, forType: .string)
                        copied = true
                    }
                }
            }
            ToolPanel(title: "Keeping your Mac awake", symbol: "sun.max") {
                VStack(alignment: .leading, spacing: 14) {
                    if let snapshot {
                        if !snapshot.assertionsAvailable {
                            Label("Current sleep requests couldn’t be determined.", systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        } else if snapshot.blockers.isEmpty {
                            Label("No app sleep blockers identified", systemImage: "checkmark.circle.fill")
                                .font(.headline).foregroundStyle(.green)
                        } else {
                            Text("\(snapshot.blockers.count) active sleep \(snapshot.blockers.count == 1 ? "request" : "requests")").font(.headline)
                            ForEach(snapshot.blockers) { assertion in
                                Divider()
                                assertionRow(assertion)
                            }
                        }
                        Text("These requests can be normal during playback, downloads, or calls. Save your work and finish the activity in the owning app if you want your Mac to sleep. Hardware, power settings, and user activity can also keep it awake.")
                            .font(.callout).foregroundStyle(.secondary)
                        if snapshot.assertions.contains(where: { !$0.preventsSleep }) {
                            DisclosureGroup("Other activity") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(snapshot.assertions.filter { !$0.preventsSleep }) { assertion in assertionRow(assertion) }
                                }.padding(.top, 8)
                            }
                        }
                    } else { ProgressView("Checking sleep requests…").padding(.vertical, 12) }
                }
            }
            ToolPanel(title: "Recent sleep and wake events", symbol: "clock.arrow.circlepath") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A brief background wake lets macOS do work while the display stays dark. The recorded reason can be a hardware code; it does not always identify one app.")
                        .foregroundStyle(.secondary)
                    if let snapshot {
                        if snapshot.events.isEmpty {
                            Label("No recent events available", systemImage: "clock.badge.questionmark").foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.events) { event in
                            Divider()
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: event.kind == "Sleep" ? "moon.fill" : "sun.max.fill")
                                    .foregroundStyle(event.kind == "Sleep" ? Color.indigo : Color.orange).frame(width: 24)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(event.title).font(.headline)
                                        Spacer()
                                        Text(event.timestamp).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(event.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    } else { ProgressView("Reading recent history…").padding(.vertical, 12) }
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
                DisclosureGroup("View current sleep evidence") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(snapshot.assertionEvidence).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 220).padding(.top, 8)
                }
                Text("Inspected \(snapshot.collectedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.task { if snapshot == nil { await refresh() } }
    }

    private func assertionRow(_ assertion: SleepAssertion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: assertion.appURL == nil ? "gearshape" : "app.fill")
                .font(.title2).foregroundStyle(.indigo).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(assertion.appURL?.deletingPathExtension().lastPathComponent ?? assertion.processName).font(.headline)
                Text(assertion.effect).font(.callout)
                Text(assertion.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(assertion.processName) · Process \(assertion.processID)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = assertion.appURL {
                Button("Show App", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
            }
        }
    }

    @MainActor private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        copied = false
        snapshot = await SleepDiagnostics.collect()
        isRefreshing = false
    }
}
