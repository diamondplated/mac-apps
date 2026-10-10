import ApplicationServices
import Cocoa
import XCTest
@testable import DockPeek

final class TabServiceIntegrationTests: XCTestCase {
    // Opt-in, read-only check against a running browser. Never changes tabs or
    // requests permissions as part of the ordinary regression suite.
    func testLiveChromeTabDiscovery() throws {
        guard ProcessInfo.processInfo.environment["DOCKPEEK_TEST_CHROME"] == "1" else {
            throw XCTSkip("Set DOCKPEEK_TEST_CHROME=1 to inspect a running Chrome instance")
        }
        XCTAssertTrue(AXIsProcessTrusted(), "The test host needs existing Accessibility access")
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first)
        var value: AnyObject?
        XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value), .success)
        let windows = try XCTUnwrap(value as? [AXUIElement])
        let start = ProcessInfo.processInfo.systemUptime
        let lists = windows.map { TabService.tabs(in: $0, bundleIdentifier: app.bundleIdentifier) }.filter { !$0.isEmpty }
        XCTAssertFalse(lists.isEmpty, "Open a Chrome window with a visible tab strip")
        for tabs in lists {
            XCTAssertEqual(tabs.filter(\.isSelected).count, 1)
            XCTAssertTrue(tabs.allSatisfy { !$0.title.isEmpty && $0.axElement != nil })
            for tab in tabs {
                let element = try XCTUnwrap(tab.axElement)
                var actions: CFArray?
                XCTAssertEqual(AXUIElementCopyActionNames(element, &actions), .success)
                let supportsPress = (actions as? [String] ?? []).contains(kAXPressAction)
                var valueSettable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
                XCTAssertTrue(supportsPress || valueSettable.boolValue, "Each tab must expose a supported selection action")
            }
        }
        print("Chrome discovery: \(lists.count) tabbed windows, \(lists.reduce(0) { $0 + $1.count }) tabs, \(ProcessInfo.processInfo.systemUptime - start)s")
    }
}
