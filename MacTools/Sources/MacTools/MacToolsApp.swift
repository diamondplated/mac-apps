import AppKit
import SwiftUI

@main
struct MacToolsApp: App {
    @StateObject private var library = LibraryModel()
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        Window("Mac Tools", id: "library") {
            LibraryView(library: library, updater: updater)
                .frame(minWidth: 880, minHeight: 650)
                .tint(.indigo)
        }
        .defaultSize(width: 1050, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Divider()
                Button("Refresh Apps") { Task { await library.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(library.isBusy)
            }
        }
        Settings {
            TabView {
                ManagerUpdatesView(updater: updater).padding(24)
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                ToolSettingsView(library: library).padding(24)
                    .tabItem { Label("Tool Settings", systemImage: "slider.horizontal.3") }
            }.frame(width: 720, height: 680).tint(.indigo)
        }
    }
}
