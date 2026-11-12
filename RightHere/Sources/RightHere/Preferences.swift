import AppKit
import FinderSync
import RightHereCore

/// The settings bridge: the Mac Tools manager reads and writes RightHere's settings through it.
enum Preferences {
    static let identifier = RightHereSettings.domain
    static let changed = Notification.Name("com.andrew.mactools.settingsChanged")

    static var availableTerminals: [Terminal] {
        Terminal.available { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    static func runCommand(_ arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 2, ["read", "write"].contains(arguments[1]) else { throw SettingsError.invalid("Usage: --mac-tools-settings read|write") }
            let store = SettingsStore(defaults: .standard)
            let terminals = availableTerminals
            if arguments[1] == "write" {
                let patch = try SettingsPatch(data: FileHandle.standardInput.readDataToEndOfFile(), availableTerminals: terminals)
                store.write(patch)
                store.defaults.synchronize()
                DistributedNotificationCenter.default().postNotificationName(changed, object: identifier, userInfo: nil, deliverImmediately: true)
            }
            let snapshot = store.snapshot(availableTerminals: terminals, extensionEnabled: FIFinderSyncController.isExtensionEnabled)
            var data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            data.append(10)
            FileHandle.standardOutput.write(data)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); return 1
        }
    }
}
