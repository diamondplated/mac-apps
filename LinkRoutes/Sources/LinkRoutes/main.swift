import AppKit
import Foundation
if CommandLine.arguments.dropFirst().first == "--mac-tools-settings" {
    exit(Preferences.runCommand(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.contains("--self-check") {
    guard SelfCheck.run() else { exit(1) }
    print("LinkRoutes self-check passed"); exit(0)
}
MainActor.assumeIsolated {
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
}
