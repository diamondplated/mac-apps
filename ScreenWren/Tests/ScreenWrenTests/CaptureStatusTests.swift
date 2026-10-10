import AppKit
import XCTest

@testable import ScreenWren

final class CaptureStatusTests: XCTestCase {
    func testCaptureStatusCannotHideAnUnavailableShortcut() {
        let captured = ScreenWrenStatus(message: "ScreenWren — Captured and copied")
        let warning = shortcutAwareStatus(captured, hasUnavailableShortcuts: true)
        XCTAssertTrue(warning.message.contains(captured.message))
        XCTAssertTrue(warning.message.contains("shortcut is unavailable"))
        XCTAssertEqual(warning.symbolName, "exclamationmark.triangle")
        let recovered = shortcutAwareStatus(captured, hasUnavailableShortcuts: false)
        XCTAssertEqual(recovered.message, captured.message)
        XCTAssertEqual(recovered.symbolName, captured.symbolName)
    }
    @MainActor func testOrdinaryStatusStaysQuietAndRemainsInMenu() throws {
        _ = NSApplication.shared
        let status = ScreenWrenStatus(message: "ScreenWren — Image copied")
        let presenter = CaptureStatusPresenter { _ in XCTFail("Unexpected recovery action") }
        presenter.update(status)
        XCTAssertNil(presenter.notice)
        let delegate = AppDelegate()
        delegate.showStatus(status)
        XCTAssertEqual(delegate.latestStatus.message, status.message)
        let item = captureStatusMenuItem(for: delegate.latestStatus)
        XCTAssertFalse(item.isEnabled)
        XCTAssertNil(item.action)
        let view = try XCTUnwrap(item.view)
        let label = try XCTUnwrap(view.subviews.first as? NSTextField)
        XCTAssertEqual(label.stringValue, status.message)
    }

    @MainActor func testMenuStatusWrapsInsideBoundedWidth() throws {
        let status = ScreenWrenStatus(message: "ScreenWren — Newer clipboard content preserved. Your capture is available in Recent Captures for this session.")
        let view = try XCTUnwrap(captureStatusMenuItem(for: status).view)
        let label = try XCTUnwrap(view.subviews.first as? NSTextField)
        XCTAssertEqual(label.frame.width, 280)
        XCTAssertGreaterThan(label.frame.height, 20)
        XCTAssertEqual(label.stringValue, status.message)
    }

    @MainActor func testAttentionPanelNeverBecomesKeyAndNextStatusDismissesIt() throws {
        _ = NSApplication.shared
        let presenter = CaptureStatusPresenter { _ in XCTFail("Unexpected recovery action") }
        presenter.update(ScreenWrenStatus(message: "ScreenWren — Target unavailable", needsAttention: true, recoveryAction: .capture))
        let notice = try XCTUnwrap(presenter.notice)
        defer { notice.close() }
        let window = try XCTUnwrap(notice.window)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        presenter.update(ScreenWrenStatus(message: "ScreenWren — Selecting…"))
        XCTAssertNil(presenter.notice)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testRecoveryButtonClosesNoticeBeforeDispatchingAction() throws {
        _ = NSApplication.shared
        var selected: CaptureStatusRecoveryAction?
        let presenter = CaptureStatusPresenter { selected = $0 }
        presenter.update(ScreenWrenStatus(message: "ScreenWren — Capture retained in Recents", needsAttention: true, recoveryAction: .recents))
        let notice = try XCTUnwrap(presenter.notice)
        defer { notice.close() }
        let content = try XCTUnwrap(notice.window?.contentView?.subviews.first as? NSStackView)
        let actions = try XCTUnwrap(content.arrangedSubviews.last as? NSStackView)
        let button = try XCTUnwrap(actions.arrangedSubviews.last as? NSButton)
        XCTAssertEqual(button.title, "Browse Recents")
        button.performClick(nil)
        XCTAssertEqual(selected, .recents)
        XCTAssertNil(presenter.notice)
        XCTAssertFalse(notice.window?.isVisible ?? true)
    }

    @MainActor func testAttentionPanelExpires() async throws {
        _ = NSApplication.shared
        let notice = CaptureStatusWindow(status: ScreenWrenStatus(message: "ScreenWren — Target unavailable", needsAttention: true)) { _ in }
        defer { notice.close() }
        let closed = expectation(description: "Transient status expires")
        notice.onClose = { closed.fulfill() }
        notice.present(duration: .milliseconds(10))
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertFalse(notice.window?.isVisible ?? true)
    }
}
