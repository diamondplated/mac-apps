import Carbon
import ScrollSplitCore

/// The two global shortcuts, registered as Carbon hot keys so they cost nothing while
/// idle and need no key tap. Registered only while ScrollSplit is on and a shortcut is
/// assigned; re-registered only when the assignments change.
final class HotKeys {
    private static let signature: OSType = 0x5353_4B59 // SSKY
    private var handler: EventHandlerRef?
    private var registrations: [ShortcutCommand: EventHotKeyRef] = [:]
    private var registered: [ShortcutCommand: KeyShortcut] = [:]
    private(set) var failures: Set<ShortcutCommand> = []
    var action: ((ShortcutCommand) -> Void)?

    func configure(_ shortcuts: [ShortcutCommand: KeyShortcut]) {
        guard shortcuts != registered else { return }
        unregisterAll()
        guard !shortcuts.isEmpty else { return }
        installHandler()
        for (index, command) in ShortcutCommand.allCases.enumerated() {
            guard let shortcut = shortcuts[command] else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: UInt32(index + 1)),
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference { registrations[command] = reference } else { failures.insert(command) }
        }
        registered = shortcuts
    }

    func unregisterAll() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        registered.removeAll()
        failures.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            let commands = ShortcutCommand.allCases
            guard status == noErr, identifier.signature == HotKeys.signature,
                  identifier.id >= 1, Int(identifier.id) <= commands.count else { return OSStatus(eventNotHandledErr) }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            let command = commands[Int(identifier.id) - 1]
            DispatchQueue.main.async { hotKeys.action?(command) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
