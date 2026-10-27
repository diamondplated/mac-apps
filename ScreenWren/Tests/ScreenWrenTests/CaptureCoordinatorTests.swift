import AppKit
import ScreenCaptureKit
import XCTest

@testable import ScreenWren

@MainActor
private final class CaptureGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    var isWaiting: Bool { continuation != nil }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(_ result: Result<Value, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor
private final class CaptureTestContext {
    let name = "ScreenWrenTests.Coordinator.\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: WorkflowPreferences
    let pasteboard = NSPasteboard.withUniqueName()
    let target: SelectionTarget
    let existingWindows: Set<ObjectIdentifier>

    init() throws {
        _ = NSApplication.shared
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        preferences = WorkflowPreferences(defaults: defaults)
        guard let screen = NSScreen.main else { throw XCTSkip("A display is required for a synthetic region identity") }
        let rect = CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10, width: 20, height: 20)
        target = .region(try XCTUnwrap(DisplayRegion(rect: rect, screen: screen)))
        existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        pasteboard.setString("original", forType: .string)
    }

    func cleanUp() {
        for window in NSApp.windows
        where !existingWindows.contains(ObjectIdentifier(window)) && window.contentViewController is EditorViewController {
            window.performClose(nil)
        }
        defaults.removePersistentDomain(forName: name)
        pasteboard.releaseGlobally()
    }
}

final class CaptureCoordinatorTests: XCTestCase {
    private enum TestFailure: Error { case timeout, clipboard }

    private func image(width: Int = 20) throws -> CGImage {
        try renderCGImage(width: width, height: 20) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: 20))
        }
    }

    @MainActor private func waitUntil(
        _ description: String, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
        throw TestFailure.timeout
    }

    @MainActor func testNewCaptureOvertakesDelayedImageWithoutStaleDeliveryOrEditor() async throws {
        let context = try CaptureTestContext()
        defer { context.cleanUp() }
        let oldImage = try image()
        let newImage = try image(width: 22)
        let gate = CaptureGate<SendableImage>()
        defer { gate.complete(.failure(CancellationError())) }
        var acquisitionCount = 0
        var copiedWidths: [Int] = []
        var services = CaptureServices()
        services.screenshot = { _ in
            acquisitionCount += 1
            return acquisitionCount == 1 ? (try await gate.value()).image : newImage
        }
        services.copyImage = { image, pasteboard in
            copiedWidths.append(image.width)
            pasteboard.clearContents()
            pasteboard.setString("image-\(image.width)", forType: .string)
        }
        let coordinator = CaptureCoordinator(preferences: context.preferences, pasteboard: context.pasteboard, services: services)
        let oldGeneration = coordinator.supersedePendingCapture()
        let oldTicket = ClipboardTicket(on: context.pasteboard)
        let oldTask = Task { @MainActor in
            await coordinator.capture(target: context.target, intent: .image, generation: oldGeneration,
                clipboardGeneration: oldTicket.generation, clipboardChangeCount: oldTicket.changeCount, rememberTarget: true)
        }
        try await waitUntil("first acquisition") { gate.isWaiting }
        context.preferences.destination = .clipboard
        let newGeneration = coordinator.supersedePendingCapture()
        let newTicket = ClipboardTicket(on: context.pasteboard)
        await coordinator.capture(target: context.target, intent: .image, generation: newGeneration,
            clipboardGeneration: newTicket.generation, clipboardChangeCount: newTicket.changeCount, rememberTarget: false)
        let deliveredRecentID = try XCTUnwrap(coordinator.recentCaptures.first?.id)
        let clipboardCount = context.pasteboard.changeCount
        gate.complete(.success(SendableImage(image: oldImage)))
        await oldTask.value
        XCTAssertEqual(copiedWidths, [22])
        XCTAssertEqual(context.pasteboard.string(forType: .string), "image-22")
        XCTAssertEqual(context.pasteboard.changeCount, clipboardCount)
        XCTAssertEqual(coordinator.recentCaptures.map(\.id), [deliveredRecentID])
        XCTAssertFalse(coordinator.menuState.canRepeat, "The superseded request must not set its repeat target")
        XCTAssertEqual(coordinator.menuState.editorCount, 0)
    }

    @MainActor func testStalePermissionFailureDoesNotInterruptNewerWork() async throws {
        let context = try CaptureTestContext()
        defer { context.cleanUp() }
        let gate = CaptureGate<SendableImage>()
        defer { gate.complete(.failure(CancellationError())) }
        var services = CaptureServices()
        services.screenshot = { _ in (try await gate.value()).image }
        let coordinator = CaptureCoordinator(preferences: context.preferences, pasteboard: context.pasteboard, services: services)
        var statuses: [String] = []
        var permissionRequests = 0
        coordinator.onStatus = { statuses.append($0.message) }
        coordinator.onPermissionRequired = { _ in permissionRequests += 1 }
        let generation = coordinator.supersedePendingCapture()
        let ticket = ClipboardTicket(on: context.pasteboard)
        let task = Task { @MainActor in
            await coordinator.capture(target: context.target, intent: .image, generation: generation,
                clipboardGeneration: ticket.generation, clipboardChangeCount: ticket.changeCount, rememberTarget: true)
        }
        try await waitUntil("pending acquisition") { gate.isWaiting }
        _ = coordinator.supersedePendingCapture()
        gate.complete(.failure(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)))
        await task.value
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(context.pasteboard.string(forType: .string), "original")
        XCTAssertTrue(coordinator.recentCaptures.isEmpty)
        XCTAssertFalse(coordinator.menuState.canRepeat)
        XCTAssertEqual(coordinator.menuState.editorCount, 0)
    }

    @MainActor func testStaleEmptyFrontWindowLookupLeavesNewerCaptureUntouched() async throws {
        let context = try CaptureTestContext()
        defer { context.cleanUp() }
        let fixture = try image()
        let gate = CaptureGate<Bool>()
        defer { gate.complete(.failure(CancellationError())) }
        var returnedLookup = false
        var services = CaptureServices()
        services.hasScreenAccess = { true }
        services.frontWindow = {
            _ = try await gate.value()
            returnedLookup = true
            return nil
        }
        services.screenshot = { _ in fixture }
        services.copyImage = { _, pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("newer capture", forType: .string)
        }
        let coordinator = CaptureCoordinator(preferences: context.preferences, pasteboard: context.pasteboard, services: services)
        var statuses: [String] = []
        var permissionRequests = 0
        coordinator.onStatus = { statuses.append($0.message) }
        coordinator.onPermissionRequired = { _ in permissionRequests += 1 }
        coordinator.captureFrontWindow()
        try await waitUntil("front-window lookup") { gate.isWaiting }
        let generation = coordinator.supersedePendingCapture()
        let ticket = ClipboardTicket(on: context.pasteboard)
        await coordinator.capture(target: context.target, intent: .image, generation: generation,
            clipboardGeneration: ticket.generation, clipboardChangeCount: ticket.changeCount, rememberTarget: true)
        let deliveredRecentIDs = coordinator.recentCaptures.map(\.id)
        XCTAssertEqual(deliveredRecentIDs.count, 1)
        let deliveredStatuses = statuses
        let clipboardCount = context.pasteboard.changeCount
        let repeatTitle = coordinator.menuState.repeatTitle
        XCTAssertTrue(coordinator.menuState.canRepeat)
        gate.complete(.success(true))
        try await waitUntil("stale empty lookup completion") { returnedLookup }
        XCTAssertEqual(statuses, deliveredStatuses)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(context.pasteboard.changeCount, clipboardCount)
        XCTAssertEqual(context.pasteboard.string(forType: .string), "newer capture")
        XCTAssertEqual(coordinator.recentCaptures.map(\.id), deliveredRecentIDs)
        XCTAssertEqual(coordinator.menuState.repeatTitle, repeatTitle)
        XCTAssertTrue(coordinator.menuState.canRepeat)
        XCTAssertEqual(coordinator.menuState.editorCount, 0)
    }

    @MainActor func testClipboardChangeDuringOCRPreservesNewerOwner() async throws {
        let context = try CaptureTestContext()
        defer { context.cleanUp() }
        let fixture = try image()
        let gate = CaptureGate<String>()
        defer { gate.complete(.failure(CancellationError())) }
        var services = CaptureServices()
        services.screenshot = { _ in fixture }
        services.text = { _ in try await gate.value() }
        let coordinator = CaptureCoordinator(preferences: context.preferences, pasteboard: context.pasteboard, services: services)
        var statuses: [ScreenWrenStatus] = []
        coordinator.onStatus = { statuses.append($0) }
        let generation = coordinator.supersedePendingCapture()
        let ticket = ClipboardTicket(on: context.pasteboard)
        let task = Task { @MainActor in
            await coordinator.capture(target: context.target, intent: .text, generation: generation,
                clipboardGeneration: ticket.generation, clipboardChangeCount: ticket.changeCount, rememberTarget: false)
        }
        try await waitUntil("OCR") { gate.isWaiting }
        context.pasteboard.clearContents()
        context.pasteboard.setString("newer owner", forType: .string)
        let count = context.pasteboard.changeCount
        gate.complete(.success("recognized text"))
        await task.value
        XCTAssertEqual(context.pasteboard.string(forType: .string), "newer owner")
        XCTAssertEqual(context.pasteboard.changeCount, count)
        XCTAssertTrue(coordinator.recentCaptures.isEmpty)
        XCTAssertFalse(coordinator.menuState.canRepeat)
        XCTAssertEqual(coordinator.menuState.editorCount, 0)
        let status = try XCTUnwrap(statuses.last)
        XCTAssertTrue(status.needsAttention)
        XCTAssertEqual(status.recoveryAction, .text)
        XCTAssertEqual(status.recoveryAction?.title, "Select Text Again")
    }

    @MainActor func testFinishPreservesPendingThirdScrollingFrame() async throws {
        let context = try CaptureTestContext()
        defer { context.cleanUp() }
        let fixture = try image()
        let gate = CaptureGate<SendableImage>()
        defer { gate.complete(.failure(CancellationError())) }
        var acquisitions = 0
        var stitchedCounts: [Int] = []
        var services = CaptureServices()
        services.screenshot = { _ in
            acquisitions += 1
            return acquisitions == 3 ? (try await gate.value()).image : fixture
        }
        services.overlap = { _, _, _ in 5 }
        services.stitch = { images in stitchedCounts.append(images.count); return fixture }
        services.copyImage = { _, _ in XCTFail("Scrolling capture must not copy automatically") }
        let coordinator = CaptureCoordinator(preferences: context.preferences, pasteboard: context.pasteboard, services: services)
        await coordinator.startScrollingSession(target: context.target, generation: coordinator.supersedePendingCapture())
        coordinator.primaryAction()
        try await waitUntil("second frame") { coordinator.menuState.scrollingSegments == 2 && !coordinator.menuState.isCapturingScrollingSegment }
        coordinator.primaryAction()
        try await waitUntil("third acquisition") { gate.isWaiting }
        coordinator.finishScrollingCapture()
        XCTAssertTrue(coordinator.menuState.isCapturingScrollingSegment)
        XCTAssertFalse(coordinator.menuState.isStitching)
        XCTAssertEqual(coordinator.menuState.scrollingSegments, 2)
        XCTAssertTrue(stitchedCounts.isEmpty)
        gate.complete(.success(SendableImage(image: fixture)))
        try await waitUntil("third committed frame") { coordinator.menuState.scrollingSegments == 3 && !coordinator.menuState.isCapturingScrollingSegment }
        coordinator.finishScrollingCapture()
        try await waitUntil("stitched editor") { coordinator.menuState.editorCount == 1 && !coordinator.menuState.isStitching }
        XCTAssertEqual(stitchedCounts, [3])
        XCTAssertFalse(coordinator.menuState.isScrolling)
        XCTAssertTrue(coordinator.recentCaptures.isEmpty)
        XCTAssertFalse(coordinator.menuState.canRepeat)
        XCTAssertEqual(context.pasteboard.string(forType: .string), "original")
    }

    @MainActor func testCancelScrollingDiscardsPendingCompletionWithoutError() async throws {
        let context = try CaptureTestContext()
        defer { context.cleanUp() }
        let fixture = try image()
        let gate = CaptureGate<SendableImage>()
        defer { gate.complete(.failure(CancellationError())) }
        var acquisitions = 0
        var returnedPendingImage = false
        var services = CaptureServices()
        services.screenshot = { _ in
            acquisitions += 1
            if acquisitions == 1 { return fixture }
            let result = (try await gate.value()).image
            returnedPendingImage = true
            return result
        }
        services.overlap = { _, _, _ in XCTFail("Cancelled frame must not enter overlap processing"); return 5 }
        services.stitch = { _ in XCTFail("Cancelled session must not stitch"); return fixture }
        let coordinator = CaptureCoordinator(preferences: context.preferences, pasteboard: context.pasteboard, services: services)
        var statuses: [String] = []
        coordinator.onStatus = { statuses.append($0.message) }
        await coordinator.startScrollingSession(target: context.target, generation: coordinator.supersedePendingCapture())
        coordinator.primaryAction()
        try await waitUntil("pending scrolling frame") { gate.isWaiting }
        coordinator.cancelScrollingCapture()
        let statusesAfterCancellation = statuses
        gate.complete(.success(SendableImage(image: fixture)))
        try await waitUntil("cancelled acquisition completion") { returnedPendingImage }
        XCTAssertEqual(statuses, statusesAfterCancellation)
        XCTAssertFalse(coordinator.menuState.isScrolling)
        XCTAssertFalse(coordinator.menuState.isCapturingScrollingSegment)
        XCTAssertEqual(coordinator.menuState.scrollingSegments, 0)
        XCTAssertEqual(coordinator.menuState.editorCount, 0)
        XCTAssertTrue(coordinator.recentCaptures.isEmpty)
        XCTAssertEqual(context.pasteboard.string(forType: .string), "original")
    }

    @MainActor func testReviewedImageSurvivesClipboardFailureBeyondRecentBudget() throws {
        let context = try CaptureTestContext()
        defer { context.cleanUp() }
        let approvedImage = try applyRedactions(image(), bounds: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        var attemptedCopies = 0
        var services = CaptureServices()
        services.copyImage = { _, _ in attemptedCopies += 1; throw TestFailure.clipboard }
        let coordinator = CaptureCoordinator(preferences: context.preferences, pasteboard: context.pasteboard,
            recentMemoryLimit: 1, services: services)
        coordinator.finishReviewedCapture(approvedImage, scale: 2, ticket: ClipboardTicket(on: context.pasteboard))
        XCTAssertEqual(attemptedCopies, 1)
        XCTAssertTrue(coordinator.recentCaptures.isEmpty)
        XCTAssertEqual(coordinator.menuState.editorCount, 1)
        XCTAssertEqual(context.pasteboard.string(forType: .string), "original")
        let editor = try XCTUnwrap(NSApp.windows.first {
            !context.existingWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is EditorViewController
        })
        var views = try XCTUnwrap(editor.contentView).subviews
        var recoveredImage: NSImage?
        while let view = views.popLast() {
            if let imageView = view as? NSImageView,
               imageView.accessibilityLabel() == "Captured image, 20 by 20 pixels" {
                recoveredImage = imageView.image
                break
            }
            views.append(contentsOf: view.subviews)
        }
        let recovered = try XCTUnwrap(recoveredImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: recovered).colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        XCTAssertEqual(pixel.redComponent, 0, accuracy: 0.01, "Recovery must contain the approved opaque mask")
        XCTAssertEqual(pixel.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(pixel.blueComponent, 0, accuracy: 0.01)
        XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.01)
    }

    @MainActor func testNewCaptureHidesThePreviousCapturesEditor() throws {
        let context = try CaptureTestContext()
        defer { context.cleanUp() }
        let coordinator = CaptureCoordinator(preferences: context.preferences, pasteboard: context.pasteboard)
        func newEditors() -> [NSWindow] {
            NSApp.windows.filter {
                !context.existingWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is EditorViewController
            }
        }
        coordinator.finishImageCapture(try image(), scale: 1, destination: .editor,
            clipboardGeneration: ClipboardDeliveryOrder.shared.begin(), clipboardChangeCount: context.pasteboard.changeCount)
        let first = try XCTUnwrap(newEditors().first)
        XCTAssertTrue(first.isVisible)

        coordinator.finishImageCapture(try image(width: 30), scale: 1, destination: .editor,
            clipboardGeneration: ClipboardDeliveryOrder.shared.begin(), clipboardChangeCount: context.pasteboard.changeCount)
        let second = try XCTUnwrap(newEditors().first { $0 !== first })
        XCTAssertFalse(first.isVisible, "The previous capture's editor must get out of the way")
        XCTAssertTrue(second.isVisible)
        XCTAssertEqual(coordinator.menuState.editorCount, 2, "Hidden, not closed: unsaved markup stays reachable")

        coordinator.showEditors()
        XCTAssertTrue(first.isVisible)
    }
}
