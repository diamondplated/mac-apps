import XCTest
@testable import DockPeek

final class WindowLayoutTests: XCTestCase {
    // MARK: Fixtures

    private func raw(_ vendor: UInt32 = 1, _ model: UInt32 = 1, _ serial: UInt32 = 1, builtIn: Bool = false,
                     _ frame: CGRect, visible: CGRect? = nil) -> RawDisplay {
        RawDisplay(vendor: vendor, model: model, serial: serial, isBuiltIn: builtIn, frame: frame, visibleFrame: visible ?? frame)
    }
    private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private func key(_ displays: [RawDisplay]) -> String { Arrangement.key(for: DisplayIdentity.displays(from: displays)) }
    private func remembered(_ bundle: String, _ title: String, _ order: Int, display: String = "builtin") -> RememberedWindow {
        RememberedWindow(bundleID: bundle, title: title, order: order, display: display, x: 0.1, y: 0.1, width: 0.5, height: 0.5)
    }

    // MARK: Arrangement identity

    func testSameDisplaysRenumberedOrReorderedAreTheSameArrangement() {
        let external = CGRect(x: 1440, y: -180, width: 2560, height: 1440)
        let a = key([raw(builtIn: true, laptop), raw(10, 20, 30, external)])
        let reordered = key([raw(10, 20, 30, external), raw(builtIn: true, laptop)])
        XCTAssertEqual(a, reordered)
        // The origin moving (a different display becoming primary) is not a different arrangement.
        let shifted = key([
            raw(builtIn: true, laptop.offsetBy(dx: 500, dy: 300)),
            raw(10, 20, 30, external.offsetBy(dx: 500, dy: 300))
        ])
        XCTAssertEqual(a, shifted)
    }
    func testDifferentPositionOrMissingDisplayIsADifferentArrangement() {
        let right = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let left = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let above = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
        let base = key([raw(builtIn: true, laptop), raw(10, 20, 30, right)])
        XCTAssertNotEqual(base, key([raw(builtIn: true, laptop), raw(10, 20, 30, left)]))
        XCTAssertNotEqual(base, key([raw(builtIn: true, laptop), raw(10, 20, 30, above)]))
        XCTAssertNotEqual(base, key([raw(builtIn: true, laptop)]))
        XCTAssertNotEqual(base, key([raw(builtIn: true, laptop), raw(10, 20, 31, right)]))
        XCTAssertNotEqual(key([raw(builtIn: true, laptop)]), key([raw(10, 20, 30, laptop)]))
    }
    func testResolutionChangeKeepsTheArrangement() {
        let a = key([raw(builtIn: true, laptop), raw(10, 20, 30, CGRect(x: 1440, y: 0, width: 2560, height: 1440))])
        let b = key([raw(builtIn: true, laptop), raw(10, 20, 30, CGRect(x: 1440, y: 0, width: 1920, height: 1080))])
        XCTAssertEqual(a, b)
    }
    func testIdenticalDisplaysAreToldApartByPosition() {
        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let displays = DisplayIdentity.displays(from: [raw(5, 5, 0, right), raw(5, 5, 0, left)])
        XCTAssertEqual(Set(displays.map(\.id)).count, 2)
        XCTAssertEqual(displays[0].id.hasSuffix("#2"), true)
        XCTAssertEqual(displays[1].id.hasSuffix("#1"), true)
    }
    func testNoSerialNumberIsKeptInTheIdentity() {
        let display = DisplayIdentity.displays(from: [raw(10, 20, 987654321, laptop)])[0]
        XCTAssertFalse(display.id.contains("987654321"))
        XCTAssertEqual(DisplayIdentity.displays(from: [raw(builtIn: true, laptop)])[0].id, "builtin")
    }

    // MARK: Matching

    func testExactTitlesMatchRegardlessOfOrder() {
        let saved = [remembered("a", "One", 0), remembered("a", "Two", 1)]
        let open = [OpenWindowRef(bundleID: "a", title: "Two", order: 0), OpenWindowRef(bundleID: "a", title: "One", order: 1)]
        XCTAssertEqual(WindowMatcher.match(remembered: saved, open: open), [0: 1, 1: 0])
    }
    func testChangedTitleFallsBackToWindowOrder() {
        let saved = [remembered("a", "Inbox", 0), remembered("a", "Draft", 1)]
        let open = [OpenWindowRef(bundleID: "a", title: "Inbox (3)", order: 0), OpenWindowRef(bundleID: "a", title: "Draft", order: 1)]
        // Draft matches by title; the leftover pair matches by order.
        XCTAssertEqual(WindowMatcher.match(remembered: saved, open: open), [0: 0, 1: 1])
    }
    func testRepeatedTitlesPairInOrder() {
        let saved = [remembered("a", "Untitled", 0), remembered("a", "Untitled", 1)]
        let open = [OpenWindowRef(bundleID: "a", title: "Untitled", order: 0), OpenWindowRef(bundleID: "a", title: "Untitled", order: 1)]
        XCTAssertEqual(WindowMatcher.match(remembered: saved, open: open), [0: 0, 1: 1])
    }
    func testClosedWindowDoesNotMoveAnotherToItsPlace() {
        // Remembered three, one closed and the survivors' titles changed: counts differ, so nothing moves.
        let saved = [remembered("a", "X", 0), remembered("a", "Y", 1), remembered("a", "Z", 2)]
        let open = [OpenWindowRef(bundleID: "a", title: "X2", order: 0), OpenWindowRef(bundleID: "a", title: "Y2", order: 1)]
        XCTAssertEqual(WindowMatcher.match(remembered: saved, open: open), [:])
        // With titles intact, the survivors still match and the closed one is simply unused.
        let intact = [OpenWindowRef(bundleID: "a", title: "X", order: 0), OpenWindowRef(bundleID: "a", title: "Z", order: 1)]
        XCTAssertEqual(WindowMatcher.match(remembered: saved, open: intact), [0: 0, 1: 2])
    }
    func testNewWindowIsLeftAlone() {
        let saved = [remembered("a", "X", 0)]
        let open = [OpenWindowRef(bundleID: "a", title: "X", order: 0), OpenWindowRef(bundleID: "a", title: "Brand New", order: 1)]
        XCTAssertEqual(WindowMatcher.match(remembered: saved, open: open), [0: 0])
    }
    func testRepeatedTitlesWithDifferentCountsMatchOnlyWhereOrderAgrees() {
        let saved = [remembered("a", "Untitled", 0), remembered("a", "Untitled", 1)]
        let open = [OpenWindowRef(bundleID: "a", title: "Untitled", order: 0), OpenWindowRef(bundleID: "a", title: "Untitled", order: 1),
                    OpenWindowRef(bundleID: "a", title: "Untitled", order: 2)]
        XCTAssertEqual(WindowMatcher.match(remembered: saved, open: open), [0: 0, 1: 1])
    }
    func testAppsNeverMatchEachOther() {
        let saved = [remembered("a", "Same", 0)]
        let open = [OpenWindowRef(bundleID: "b", title: "Same", order: 0)]
        XCTAssertEqual(WindowMatcher.match(remembered: saved, open: open), [:])
    }

    // MARK: Geometry

    func testRelativeFrameSurvivesAResolutionChange() throws {
        let before = DisplayInfo(id: "ext", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 1440, y: 25, width: 2560, height: 1415))
        let window = CGRect(x: 1440 + 640, y: 360, width: 1280, height: 720)
        let saved = try XCTUnwrap(LayoutGeometry.remember(frame: window, bundleID: "a", title: "T", order: 0, displays: [before]))
        XCTAssertEqual(saved.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(saved.width, 0.5, accuracy: 1e-9)
        // Same display back at 1920x1080 and at a different place.
        let after = DisplayInfo(id: "ext", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1440, y: 25, width: 1920, height: 1055))
        let target = try XCTUnwrap(LayoutGeometry.target(for: saved, displays: [after]))
        XCTAssertEqual(target, CGRect(x: 1440 + 480, y: 270, width: 960, height: 540))
        // At the original resolution it comes back exactly.
        XCTAssertEqual(LayoutGeometry.target(for: saved, displays: [before]), window)
    }
    func testWindowIsRememberedOnTheDisplayHoldingMostOfIt() throws {
        let left = DisplayInfo(id: "L", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let right = DisplayInfo(id: "R", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        let straddling = CGRect(x: 800, y: 100, width: 600, height: 400)
        XCTAssertEqual(LayoutGeometry.display(for: straddling, in: [left, right])?.id, "R")
        let adrift = CGRect(x: 5000, y: 100, width: 300, height: 300)
        XCTAssertEqual(LayoutGeometry.display(for: adrift, in: [left, right])?.id, "R")
        XCTAssertNil(LayoutGeometry.display(for: adrift, in: []))
    }
    func testTargetOnAMissingDisplayIsNil() {
        XCTAssertNil(LayoutGeometry.target(for: remembered("a", "T", 0, display: "gone"), displays: []))
    }
    func testClampKeepsWindowsFullyOnScreen() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertEqual(LayoutGeometry.clamp(CGRect(x: 1300, y: 800, width: 400, height: 300), into: visible), CGRect(x: 1040, y: 600, width: 400, height: 300))
        XCTAssertEqual(LayoutGeometry.clamp(CGRect(x: -500, y: -500, width: 400, height: 300), into: visible), CGRect(x: 0, y: 25, width: 400, height: 300))
        XCTAssertEqual(LayoutGeometry.clamp(CGRect(x: 10, y: 10, width: 3000, height: 2000), into: visible), visible)
        let inside = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(LayoutGeometry.clamp(inside, into: visible), inside)
    }
    func testRestoredTargetIsClampedToTheVisibleFrameNotTheFullDisplay() throws {
        let display = DisplayInfo(id: "d", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 40, width: 1000, height: 760))
        let saved = RememberedWindow(bundleID: "a", title: "T", order: 0, display: "d", x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        XCTAssertEqual(try XCTUnwrap(LayoutGeometry.target(for: saved, displays: [display])).minY, 40)
    }
    func testBottomLeftToTopLeftConversion() {
        // A 1440x900 primary with a 25pt menu bar: AppKit's visible frame is y 0..875.
        let converted = LayoutGeometry.topLeft(fromBottomLeft: CGRect(x: 0, y: 0, width: 1440, height: 875), primaryHeight: 900)
        XCTAssertEqual(converted, CGRect(x: 0, y: 25, width: 1440, height: 875))
    }
    func testInPlaceTolerance() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertTrue(LayoutGeometry.isInPlace(frame, frame.offsetBy(dx: 1, dy: -2)))
        XCTAssertFalse(LayoutGeometry.isInPlace(frame, frame.offsetBy(dx: 3, dy: 0)))
    }

    // MARK: Merge

    func testSnapshotKeepsWindowsOfAppsThatCouldNotBeRead() {
        let existing = [remembered("a", "Old A", 0), remembered("b", "Old B", 0)]
        let current = [remembered("a", "New A", 0)]
        let merged = LayoutMerge.merged(existing: existing, current: current, readableBundles: ["a"], limit: 10)
        XCTAssertEqual(merged.map(\.title), ["New A", "Old B"])
        XCTAssertEqual(LayoutMerge.merged(existing: existing, current: [], readableBundles: ["a", "b"], limit: 10), [])
        XCTAssertEqual(LayoutMerge.merged(existing: existing, current: current, readableBundles: ["a"], limit: 1).map(\.title), ["New A"])
    }

    // MARK: Settling

    func testBurstOfDisplayChangesSettlesOnceAfterQuiet() {
        var scheduler = LayoutScheduler()
        for t in [0.0, 0.3, 0.9, 1.6] { scheduler.displaysChanged(at: t) }
        XCTAssertNil(scheduler.due(at: 2.0))
        XCTAssertNil(scheduler.due(at: 3.0))
        XCTAssertEqual(scheduler.due(at: 3.2), .settleArrangement)
        XCTAssertNil(scheduler.due(at: 10))
    }
    func testDisplayChangesNeverTimeOutWhileTheyKeepArriving() {
        var scheduler = LayoutScheduler()
        var t = 0.0
        while t < 120 { scheduler.displaysChanged(at: t); XCTAssertNil(scheduler.due(at: t)); t += 1 }
    }
    func testWindowMovementIsRememberedOnlyAfterItStops() {
        var scheduler = LayoutScheduler()
        scheduler.windowsMoved(at: 100)
        scheduler.windowsMoved(at: 101)
        XCTAssertNil(scheduler.due(at: 103))
        XCTAssertEqual(scheduler.due(at: 104.1), .saveLayout)
        XCTAssertNil(scheduler.due(at: 200))
    }
    func testAWindowThatNeverStopsMovingIsStillRememberedEventually() {
        var scheduler = LayoutScheduler()
        var saved: Double?
        var t = 0.0
        while t < 100, saved == nil {
            scheduler.windowsMoved(at: t)
            if scheduler.due(at: t) == .saveLayout { saved = t }
            t += 1
        }
        XCTAssertEqual(saved, LayoutScheduler.movementMaxWait)
    }
    func testWindowMovementDuringADisplayBurstIsNotRemembered() {
        var scheduler = LayoutScheduler()
        scheduler.windowsMoved(at: 0)
        scheduler.displaysChanged(at: 1)
        scheduler.windowsMoved(at: 1.2)
        XCTAssertEqual(scheduler.due(at: 3), .settleArrangement)
        XCTAssertNil(scheduler.due(at: 10), "the scramble must not be saved as the layout")
    }
    func testMovementRightAfterARestoreIsIgnoredForAWhile() {
        var scheduler = LayoutScheduler()
        scheduler.didRestore(at: 50)
        scheduler.windowsMoved(at: 52)
        XCTAssertNil(scheduler.due(at: 60))
        scheduler.windowsMoved(at: 56)
        XCTAssertEqual(scheduler.due(at: 60), .saveLayout)
    }
    func testWindowSignatureChangesWithMovementOnly() {
        let a = WindowSignature.of([(1, CGRect(x: 0, y: 0, width: 100, height: 100)), (2, CGRect(x: 5, y: 5, width: 50, height: 50))])
        let reordered = WindowSignature.of([(2, CGRect(x: 5, y: 5, width: 50, height: 50)), (1, CGRect(x: 0, y: 0, width: 100, height: 100))])
        let moved = WindowSignature.of([(1, CGRect(x: 10, y: 0, width: 100, height: 100)), (2, CGRect(x: 5, y: 5, width: 50, height: 50))])
        let fewer = WindowSignature.of([(1, CGRect(x: 0, y: 0, width: 100, height: 100))])
        XCTAssertEqual(a, reordered)
        XCTAssertNotEqual(a, moved)
        XCTAssertNotEqual(a, fewer)
    }

    // MARK: Storage

    func testStoreKeepsTheMostRecentlyUsedArrangements() {
        var store = LayoutStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(LayoutStore.maxArrangements + 5) {
            store.set([remembered("a", "T\(i)", 0)], for: "k\(i)", now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(store.records.count, LayoutStore.maxArrangements)
        XCTAssertNil(store.record(for: "k0"))
        XCTAssertNotNil(store.record(for: "k\(LayoutStore.maxArrangements + 4)"))
        // Using an old arrangement keeps it through the next trim.
        store.touch("k5", now: start.addingTimeInterval(1000))
        store.set([], for: "new", now: start.addingTimeInterval(1001))
        XCTAssertNotNil(store.record(for: "k5"))
        XCTAssertNil(store.record(for: "k6"))
    }
    func testStoreRoundTripsThroughAFilePrivateToTheUser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dockpeek-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LayoutStoreFile(url: directory.appendingPathComponent("Nested/WindowLayouts.json"))
        XCTAssertEqual(file.load(), LayoutStore())
        var store = LayoutStore()
        store.set([remembered("com.example.app", "Notes", 0)], for: "key", now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertTrue(file.save(store))
        XCTAssertEqual(file.load(), store)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o600)
        file.forget()
        XCTAssertEqual(file.load(), LayoutStore())
    }
    func testUnreadableStoreFileIsAnEmptyStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dockpeek-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(LayoutStoreFile(url: url).load(), LayoutStore())
    }
    func testStoredDataIsOnlyBundlesTitlesAndFrames() throws {
        var store = LayoutStore()
        store.set([remembered("com.example.app", "Notes", 0)], for: "key", now: Date())
        let json = String(decoding: try JSONEncoder().encode(store), as: UTF8.self)
        for field in ["bundleID", "title", "display", "width", "height"] { XCTAssertTrue(json.contains(field), field) }
        XCTAssertFalse(json.lowercased().contains("serial"))
    }
    func testLongTitlesAreTruncated() throws {
        let display = DisplayInfo(id: "d", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let saved = try XCTUnwrap(LayoutGeometry.remember(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), bundleID: "a",
            title: String(repeating: "x", count: 5000), order: 0, displays: [display]
        ))
        XCTAssertEqual(saved.title.count, LayoutStore.maxTitleLength)
    }
}
