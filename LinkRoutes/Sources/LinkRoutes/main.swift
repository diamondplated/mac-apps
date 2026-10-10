import AppKit
import Foundation
if CommandLine.arguments.dropFirst().first == "--mac-tools-settings" {
    exit(Preferences.runCommand(Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.contains("--self-check") {
    do {
        let url = try Routing.webURL("https://example.com/path?q=1#anchor")
        guard url.host == "example.com", try Routing.domain("EXAMPLE.COM") == "example.com", !Routing.safeProfileDirectory("../Default") else { exit(1) }
        print("LinkRoutes self-check passed"); exit(0)
    } catch { exit(1) }
}
MainActor.assumeIsolated {
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
}
