import AppKit
import SwiftUI

@main
struct MacToolsApp: App {
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        Window("Mac Tools", id: "library") {
            LibraryView(library: library)
                .frame(minWidth: 880, minHeight: 650)
                .tint(.indigo)
        }
        .defaultSize(width: 1050, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Refresh Apps") { Task { await library.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(library.isBusy)
            }
        }
        Settings {
            ToolSettingsView(library: library)
                .padding(24)
                .frame(width: 720, height: 680)
                .tint(.indigo)
        }
    }
}
