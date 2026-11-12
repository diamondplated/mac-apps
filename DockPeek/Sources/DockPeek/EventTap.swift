import Foundation
import CoreGraphics

/// A session event tap whose callback runs on its own thread, so a busy main thread
/// (rendering a panel, enumerating windows) never delays anyone's input.
///
/// Fails open: an event the handler does not claim is returned untouched, and when the
/// system disables the tap (a slow callback or user input) it is re-enabled at once.
/// `stop()` removes the tap entirely; nothing stays installed while a feature is off.
final class EventTap {
    /// Returns true to consume the event. Called on the tap thread; must be quick.
    typealias Handler = (CGEventType, CGEvent) -> Bool

    private final class Box {
        let handler: Handler
        var port: CFMachPort?
        init(handler: @escaping Handler) { self.handler = handler }
    }

    private static let thread = TapThread()

    private let mask: CGEventMask
    private let handler: Handler
    private var box: Box?
    private var source: CFRunLoopSource?

    init(events: [CGEventType], handler: @escaping Handler) {
        mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        self.handler = handler
    }

    deinit { stop() }

    var isInstalled: Bool { box != nil }

    /// Installs the tap. Returns false when the system refuses it (no Accessibility access).
    @discardableResult
    func start() -> Bool {
        guard box == nil else { return true }
        let box = Box(handler: handler)
        let userInfo = Unmanaged.passUnretained(box).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else { return false }
        box.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.box = box
        self.source = source
        Self.thread.perform { runLoop in
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return true
    }

    func stop() {
        guard let box, let source else { return }
        self.box = nil
        self.source = nil
        // Tear down on the tap thread so no callback is mid-flight when the box goes away.
        Self.thread.perform { runLoop in
            if let port = box.port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                CFMachPortInvalidate(port)
            }
            box.port = nil
        }
    }

    fileprivate static func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let box = Unmanaged<Box>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = box.port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard box.port != nil else { return Unmanaged.passUnretained(event) }
        return box.handler(type, event) ? nil : Unmanaged.passUnretained(event)
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    EventTap.handle(proxy, type, event, userInfo)
}

/// One long-lived thread with a run loop for every tap DockPeek installs.
private final class TapThread {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init() {
        let thread = Thread { [weak self] in
            // A port keeps the run loop alive while no tap is installed.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            self?.runLoop = CFRunLoopGetCurrent()
            self?.ready.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "DockPeek event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Runs `work` on the tap thread and waits for it.
    func perform(_ work: @escaping (CFRunLoop) -> Void) {
        guard let runLoop else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            work(runLoop)
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
    }
}
