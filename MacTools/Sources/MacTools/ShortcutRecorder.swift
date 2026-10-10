import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: RecordedShortcut?
    let title: String
    let onRecord: (RecordedShortcut?) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.setAccessibilityLabel("\(title) shortcut")
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.shortcut = shortcut
        field.onRecord = onRecord
    }
}

final class RecorderField: NSTextField {
    var shortcut: RecordedShortcut? { didSet { if window?.firstResponder !== self { updateText() } } }
    var onRecord: ((RecordedShortcut?) -> Void)?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = true
        drawsBackground = true
        alignment = .center
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        focusRingType = .exterior
        setAccessibilityRole(.textField)
        setAccessibilityElement(true)
        toolTip = "Click and press a shortcut. Delete clears it; Escape cancels."
        updateText()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { stringValue = "Type shortcut…" }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        updateText()
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape { window?.makeFirstResponder(nil); return }
        if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
            window?.makeFirstResponder(nil)
            onRecord?(nil)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let key: (String, String)
        switch Int(event.keyCode) {
        case kVK_Return: key = ("\r", "↩")
        case kVK_Tab: key = ("\t", "⇥")
        case kVK_Space: key = (" ", "Space")
        case kVK_LeftArrow: key = (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), "←")
        case kVK_RightArrow: key = (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), "→")
        case kVK_UpArrow: key = (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), "↑")
        case kVK_DownArrow: key = (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), "↓")
        default:
            guard let character = event.charactersIgnoringModifiers?.first, !character.isWhitespace else { NSSound.beep(); return }
            key = (String(character).lowercased(), String(character).uppercased())
        }
        let shortcut = RecordedShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyEquivalent: key.0, keyLabel: key.1)
        window?.makeFirstResponder(nil)
        onRecord?(shortcut)
    }

    private func updateText() { stringValue = shortcut?.displayName ?? "None"; setAccessibilityValue(stringValue) }
}
