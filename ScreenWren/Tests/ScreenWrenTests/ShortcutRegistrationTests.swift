import AppKit
import Carbon.HIToolbox
import XCTest

@testable import ScreenWren

final class ShortcutRegistrationTests: XCTestCase {
    private enum CarbonTestError: Error { case failed(OSStatus) }

    private func shortcut(_ keyCode: Int, label: String,
                          modifiers: UInt32 = UInt32(controlKey | optionKey | shiftKey)) -> Shortcut {
        Shortcut(keyCode: UInt32(keyCode), carbonModifiers: modifiers,
            keyEquivalent: "", keyLabel: label)
    }

    private func store() throws -> (ShortcutStore, UserDefaults, String) {
        let name = "ScreenWrenTests.ShortcutRegistration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = ShortcutStore(defaults: defaults)
        for command in ShortcutCommand.allCases { store.set(nil, for: command) }
        return (store, defaults, name)
    }

    @MainActor private func hold(_ shortcut: Shortcut) throws -> EventHotKeyRef {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
            EventHotKeyID(signature: 0x53575453, id: 99), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        XCTAssertEqual(status, noErr, "The uncommon test shortcut must be available before creating a deliberate conflict")
        guard status == noErr else { throw CarbonTestError.failed(status) }
        return try XCTUnwrap(reference)
    }

    @MainActor private func dispatch(_ command: ShortcutCommand) throws {
        var createdEvent: EventRef?
        let creation = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &createdEvent)
        XCTAssertEqual(creation, noErr)
        guard creation == noErr else { throw CarbonTestError.failed(creation) }
        let event = try XCTUnwrap(createdEvent)
        defer { ReleaseEvent(event) }
        var identifier = EventHotKeyID(signature: 0x5357524E, id: command.identifier)
        let parameter = SetEventParameter(event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier)
        XCTAssertEqual(parameter, noErr)
        guard parameter == noErr else { throw CarbonTestError.failed(parameter) }
        let delivery = SendEventToEventTarget(event, GetApplicationEventTarget())
        XCTAssertEqual(delivery, noErr)
        guard delivery == noErr else { throw CarbonTestError.failed(delivery) }
    }

    @MainActor func testConflictRecoveryKeepsWorkingShortcutsRegistered() async throws {
        _ = NSApplication.shared
        let (store, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let captureKey = shortcut(kVK_F19, label: "F19")
        store.set(captureKey, for: .capture)
        store.set(shortcut(kVK_F18, label: "F18"), for: .copyText)
        var conflict: EventHotKeyRef? = try hold(captureKey)
        defer { if let conflict { UnregisterEventHotKey(conflict) } }
        let dispatched = expectation(description: "Both recovered and preserved actions dispatch")
        dispatched.expectedFulfillmentCount = 2
        var captureCount = 0
        var textCount = 0
        let manager = ShortcutManager(store: store, actions: [
            .capture: { captureCount += 1; dispatched.fulfill() },
            .copyText: { textCount += 1; dispatched.fulfill() },
        ])
        var changes = 0
        manager.onChange = { changes += 1 }
        manager.registerAll()
        XCTAssertNotNil(manager.failures[.capture])
        XCTAssertNil(manager.failures[.copyText])
        let initialChanges = changes
        manager.retryUnavailableShortcuts()
        XCTAssertEqual(changes, initialChanges, "An unchanged conflict must not emit repeated status changes")
        XCTAssertEqual(UnregisterEventHotKey(try XCTUnwrap(conflict)), noErr)
        conflict = nil
        manager.retryUnavailableShortcuts()
        XCTAssertTrue(manager.failures.isEmpty)
        XCTAssertEqual(changes, initialChanges + 1)
        manager.retryUnavailableShortcuts()
        XCTAssertEqual(changes, initialChanges + 1, "Retry must leave working registrations alone")
        try dispatch(.capture)
        try dispatch(.copyText)
        await fulfillment(of: [dispatched], timeout: 2)
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(textCount, 1)
        withExtendedLifetime(manager) {}
    }

    @MainActor func testCarbonEventPassesOtherHandlersAndDispatchesExactlyOneAction() async throws {
        _ = NSApplication.shared
        let (store, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        // Separate physical combinations keep parallel XCTest workers independent.
        let modifiers = UInt32(cmdKey | optionKey | shiftKey)
        store.set(shortcut(kVK_F19, label: "F19", modifiers: modifiers), for: .capture)
        store.set(shortcut(kVK_F18, label: "F18", modifiers: modifiers), for: .copyText)
        let captured = expectation(description: "Matching capture handler dispatches")
        var captureCount = 0
        var textCount = 0
        let manager = ShortcutManager(store: store, actions: [
            .capture: { captureCount += 1; captured.fulfill() },
            .copyText: { textCount += 1 },
        ])
        manager.registerAll()
        XCTAssertTrue(manager.failures.isEmpty)
        // Copy Text installs after Capture, so this must traverse a nonmatching handler first.
        try dispatch(.capture)
        await fulfillment(of: [captured], timeout: 2)
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(textCount, 0)
        withExtendedLifetime(manager) {}
    }

    @MainActor func testMissingActionsDoNotEmitChangesOnRecoveryNotifications() throws {
        _ = NSApplication.shared
        let (store, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        store.set(shortcut(kVK_F19, label: "F19"), for: .capture)
        let manager = ShortcutManager(store: store, actions: [:])
        var changes = 0
        manager.onChange = { changes += 1 }
        manager.registerAll()
        let initialFailures = manager.failures
        let initialChanges = changes
        manager.retryUnavailableShortcuts()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertEqual(changes, initialChanges)
        XCTAssertEqual(manager.failures, initialFailures)
    }
}
