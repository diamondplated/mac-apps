import AppKit
import SwiftUI

@main
struct MacToolsApp: App {
    @StateObject private var library = LibraryModel()
    @StateObject private var updater = UpdateController()

    init() { LegacyData.remove() }

    var body: some Scene {
        Window("Mac Tools", id: "library") {
            LibraryView(library: library)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 940, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh") { Task { await library.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(library.isBusy)
            }
        }
        Settings {
            PreferencesView(library: library, updater: updater)
        }
    }
}
