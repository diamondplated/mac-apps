import Foundation
import Cocoa
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

public struct WindowInfo: Identifiable, @unchecked Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let title: String
    public let bounds: CGRect
    public let thumbnail: NSImage?
    public let appIcon: NSImage?
    public let axElement: AXUIElement?
    public let isMinimized: Bool
    public let isOnScreen: Bool
    public let tabs: [TabInfo]

    public init(
        id: CGWindowID,
        pid: pid_t,
        title: String,
        bounds: CGRect,
        thumbnail: NSImage?,
        appIcon: NSImage?,
        axElement: AXUIElement?,
        isMinimized: Bool = false,
        isOnScreen: Bool = true,
        tabs: [TabInfo] = []
    ) {
        self.id = id
        self.pid = pid
        self.title = title
        self.bounds = bounds
        self.thumbnail = thumbnail
        self.appIcon = appIcon
        self.axElement = axElement
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
        self.tabs = tabs
    }
}

/// Keeps the most recently used thumbnails; DockPeek runs all day and window IDs are never reused.
actor ThumbnailCache {
    private let limit: Int
    private var cache: [CGWindowID: NSImage] = [:]
    private var recency: [CGWindowID] = []
    
    init(limit: Int = 64) {
        self.limit = limit
    }
    
    var count: Int { cache.count }
    
    func get(_ id: CGWindowID) -> NSImage? {
        guard let image = cache[id] else { return nil }
        touch(id)
        return image
    }
    
    func set(_ id: CGWindowID, image: NSImage) {
        cache[id] = image
        touch(id)
        while recency.count > limit {
            cache[recency.removeFirst()] = nil
        }
    }
    
    private func touch(_ id: CGWindowID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }
}

enum WindowFilter {
    static func includes(title: String, subrole: String, bounds: CGRect, isMinimized: Bool) -> Bool {
        if title.isEmpty && subrole != kAXStandardWindowSubrole && subrole != kAXDialogSubrole { return false }
        // Chrome exposes tiny auxiliary controls as titled AXDialog windows.
        // Preserve minimized windows and apps that cannot report their bounds.
        if !isMinimized && bounds.width > 0 && bounds.height > 0 {
            return bounds.width >= 100 && bounds.height >= 80
        }
        return true
    }
}

public class WindowService {
    public static let shared = WindowService()
    
    private let thumbnailCache = ThumbnailCache()
    
    // Dynamic binding to CGWindowListCreateImage as legacy fallback if needed
    private typealias CGWindowListCreateImageFunc = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> CGImage?
    private static let legacyCaptureFunc: CGWindowListCreateImageFunc? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(handle, "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(sym, to: CGWindowListCreateImageFunc.self)
    }()
    
    private init() {}
    
    /// Asynchronously fetches active and minimized windows with live thumbnails for the given process ID
    public func fetchWindows(for pid: pid_t, appIcon: NSImage?, showsTabs: Bool = true, completion: @escaping ([WindowInfo]) -> Void) {
        Task {
            let windows = await self.getWindows(for: pid, appIcon: appIcon, showsTabs: showsTabs)
            DispatchQueue.main.async {
                completion(windows)
            }
        }
    }
    
    /// Returns real application windows (including minimized windows) with live thumbnails
    public func getWindows(for pid: pid_t, appIcon: NSImage?, showsTabs: Bool = true) async -> [WindowInfo] {
        // 1. Query Accessibility for true user-facing application windows.
        // This is the ground truth on macOS that filters out invisible render surfaces,
        // auxiliary background frames, and web worker layers.
        let appElement = AXUIElementCreateApplication(pid)
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        var axWindowsList: [(element: AXUIElement, id: CGWindowID, title: String, isMinimized: Bool, bounds: CGRect)] = []
        
        var axWindowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &axWindowsValue) == .success,
           let axWindows = axWindowsValue as? [AXUIElement] {
            for axWin in axWindows {
                var title = ""
                var titleVal: AnyObject?
                if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleVal) == .success,
                   let t = titleVal as? String {
                    title = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                var subrole = ""
                var subroleVal: AnyObject?
                if AXUIElementCopyAttributeValue(axWin, kAXSubroleAttribute as CFString, &subroleVal) == .success,
                   let s = subroleVal as? String {
                    subrole = s
                }
                
                // Check if truly minimized into the Dock (AXMinimized is authoritative!)
                var isMin = false
                var minVal: AnyObject?
                if AXUIElementCopyAttributeValue(axWin, "AXMinimized" as CFString, &minVal) == .success,
                   let m = minVal as? Bool {
                    isMin = m
                }
                
                var winID: CGWindowID = 0
                _ = _AXUIElementGetWindow(axWin, &winID)
                
                var bounds = CGRect.zero
                var posVal: AnyObject?
                var sizeVal: AnyObject?
                if AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posVal) == .success,
                   AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeVal) == .success,
                   let p = posVal, let s = sizeVal {
                    var pt = CGPoint.zero
                    var sz = CGSize.zero
                    if AXValueGetValue(p as! AXValue, .cgPoint, &pt) &&
                       AXValueGetValue(s as! AXValue, .cgSize, &sz) {
                        bounds = CGRect(origin: pt, size: sz)
                    }
                }
                
                guard WindowFilter.includes(title: title, subrole: subrole, bounds: bounds, isMinimized: isMin) else { continue }
                axWindowsList.append((element: axWin, id: winID, title: title, isMinimized: isMin, bounds: bounds))
            }
        }
        
        // 2. Fetch ScreenCaptureKit shareable content to map SCWindow objects for thumbnail captures
        var scWindowsByPID: [SCWindow] = []
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
            scWindowsByPID = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0
            }
        }
        
        let scWindowMap = Dictionary(scWindowsByPID.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        
        // 3. Match each real AX window to its SCWindow and capture live thumbnail
        var results: [WindowInfo] = []
        
        if !axWindowsList.isEmpty {
            for item in axWindowsList {
                var scWin: SCWindow? = nil
                if item.id != 0 {
                    scWin = scWindowMap[item.id]
                }
                if item.id == 0 && scWin == nil && !item.title.isEmpty {
                    scWin = scWindowsByPID.first(where: {
                        guard let scTitle = $0.title?.trimmingCharacters(in: .whitespacesAndNewlines), !scTitle.isEmpty else { return false }
                        return scTitle == item.title || item.title.contains(scTitle) || scTitle.contains(item.title)
                    })
                }
                if item.id == 0 && scWin == nil && item.bounds.width > 0 {
                    scWin = scWindowsByPID.first(where: {
                        abs($0.frame.width - item.bounds.width) < 10 && abs($0.frame.height - item.bounds.height) < 10
                    })
                }
                if item.id == 0 && scWin == nil && axWindowsList.count == 1 {
                    scWin = scWindowsByPID.first(where: { $0.isOnScreen }) ?? scWindowsByPID.first
                }
                
                let effectiveID = scWin?.windowID ?? item.id
                let isOnScreen = scWin?.isOnScreen ?? (!item.isMinimized)
                let effectiveBounds = scWin?.frame ?? item.bounds
                
                var thumb: NSImage? = nil
                if let sc = scWin, !item.isMinimized {
                    thumb = await captureThumbnail(for: sc)
                }
                if thumb == nil, effectiveID != 0 {
                    thumb = await thumbnailCache.get(effectiveID)
                }
                
                results.append(WindowInfo(
                    id: effectiveID,
                    pid: pid,
                    title: item.title,
                    bounds: effectiveBounds,
                    thumbnail: thumb,
                    appIcon: appIcon,
                    axElement: item.element,
                    isMinimized: item.isMinimized, // Strictly only true if AXMinimized was true!
                    isOnScreen: isOnScreen,
                    tabs: showsTabs ? TabService.tabs(in: item.element, bundleIdentifier: bundleIdentifier) : []
                ))
            }
        } else {
            // Fallback for applications without AX accessibility window enumeration:
            // Only include windows with actual non-empty titles and valid sizes
            for sc in scWindowsByPID {
                let title = (sc.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                guard sc.frame.width >= 100 && sc.frame.height >= 80 else { continue }
                if sc.frame.height <= 40 && sc.frame.width > 500 { continue } // Skip menu bar strips
                
                let thumb = await captureThumbnail(for: sc)
                results.append(WindowInfo(
                    id: sc.windowID,
                    pid: pid,
                    title: title,
                    bounds: sc.frame,
                    thumbnail: thumb,
                    appIcon: appIcon,
                    axElement: nil,
                    isMinimized: false, // Never mark as minimized unless verified by AX
                    isOnScreen: sc.isOnScreen
                ))
            }
        }
        
        // Sort: on-screen windows first, then minimized windows
        results.sort { w1, w2 in
            if w1.isMinimized != w2.isMinimized {
                return !w1.isMinimized && w2.isMinimized
            }
            return w1.id < w2.id
        }
        
        return results
    }
    
    /// Capture thumbnail image of a specific SCWindow with aspect-ratio preservation
    public func captureThumbnail(for window: SCWindow) async -> NSImage? {
        let wid = window.windowID
        
        // Try ScreenCaptureKit screenshot capture
        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let maxW: CGFloat = 420
            let maxH: CGFloat = 270
            let aspect = (window.frame.width > 0 && window.frame.height > 0) ? (window.frame.width / window.frame.height) : (16.0 / 10.0)
            var targetW = maxW
            var targetH = maxW / aspect
            if targetH > maxH {
                targetH = maxH
                targetW = maxH * aspect
            }
            config.width = max(80, Int(targetW))
            config.height = max(60, Int(targetH))
            config.showsCursor = false
            config.scalesToFit = true
            
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            
            await thumbnailCache.set(wid, image: nsImage)
            return nsImage
        } catch {
            // SC capture failed or window is offscreen
        }
        
        // Try legacy fallback if available
        if let legacyImage = captureLegacyThumbnail(for: wid) {
            await thumbnailCache.set(wid, image: legacyImage)
            return legacyImage
        }
        
        // Return cached thumbnail from earlier capture if exists
        return await thumbnailCache.get(wid)
    }
    
    /// Capture legacy thumbnail using dynamic CGWindowListCreateImage lookup
    private func captureLegacyThumbnail(for windowID: CGWindowID) -> NSImage? {
        guard let fn = Self.legacyCaptureFunc else { return nil }
        var rawCG: CGImage? = fn(CGRect.null, 1, windowID, 1 | 16)
        if rawCG == nil {
            rawCG = fn(CGRect.null, 0, windowID, 1 | 16)
        }
        guard let cg = rawCG else { return nil }
        
        let origW = CGFloat(cg.width)
        let origH = CGFloat(cg.height)
        guard origW > 0, origH > 0 else {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        
        let maxW: CGFloat = 420
        let maxH: CGFloat = 270
        let aspect = origW / origH
        var targetW = maxW
        var targetH = maxW / aspect
        if targetH > maxH {
            targetH = maxH
            targetW = maxH * aspect
        }
        
        let size = NSSize(width: targetW, height: targetH)
        let scaledImage = NSImage(size: size)
        scaledImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let nsImg = NSImage(cgImage: cg, size: NSSize(width: origW, height: origH))
        nsImg.draw(in: NSRect(origin: .zero, size: size))
        scaledImage.unlockFocus()
        return scaledImage
    }
    
    /// Focus and raise a window, unminimizing it first if it was minimized
    public func raiseWindow(_ window: WindowInfo) {
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate()
        }
        
        var axWin = window.axElement
        if axWin == nil {
            let appElement = AXUIElementCreateApplication(window.pid)
            var axWindowsValue: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &axWindowsValue) == .success,
               let axWindows = axWindowsValue as? [AXUIElement] {
                if !window.title.isEmpty {
                    for candidate in axWindows {
                        var titleVal: AnyObject?
                        if AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &titleVal) == .success,
                           let t = titleVal as? String, t == window.title {
                            axWin = candidate
                            break
                        }
                    }
                }
                if axWin == nil {
                    axWin = axWindows.first
                }
            }
        }
        
        if let targetAX = axWin {
            if window.isMinimized {
                AXUIElementSetAttributeValue(targetAX, "AXMinimized" as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(targetAX, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(targetAX, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }
    
    /// Select a tab in its owning window, restoring a minimized window first.
    @discardableResult
    public func selectTab(_ tab: TabInfo, in window: WindowInfo) -> Bool {
        // Keep the actual AX element, rather than a title or index that could now
        // identify a different tab after closing, reordering, or duplicate titles.
        raiseWindow(window)
        return TabService.select(tab)
    }

    /// Close a window via Accessibility action
    public func closeWindow(_ window: WindowInfo) {
        guard let axWindow = window.axElement else { return }
        var closeButtonValue: AnyObject?
        if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
           let closeButton = closeButtonValue {
            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        }
    }
    
    /// Minimize a window via Accessibility action
    public func minimizeWindow(_ window: WindowInfo) {
        guard let axWindow = window.axElement else { return }
        var minButtonValue: AnyObject?
        if AXUIElementCopyAttributeValue(axWindow, kAXMinimizeButtonAttribute as CFString, &minButtonValue) == .success,
           let minButton = minButtonValue {
            AXUIElementPerformAction(minButton as! AXUIElement, kAXPressAction as CFString)
        }
    }
}
