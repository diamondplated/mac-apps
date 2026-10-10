import Cocoa

if CommandLine.arguments.dropFirst().first == "--mac-tools-settings" {
    exit(ToolPreferences.runSettingsCommand(arguments: Array(CommandLine.arguments.dropFirst())))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
