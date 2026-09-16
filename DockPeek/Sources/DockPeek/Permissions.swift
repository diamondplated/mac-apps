import Foundation
import Cocoa
import ApplicationServices
import CoreGraphics

public enum PermissionStatus {
    case granted
    case denied
}

public class PermissionsManager: ObservableObject {
    public static let shared = PermissionsManager()
    
    @Published public var accessibilityStatus: PermissionStatus = .denied
    @Published public var screenCaptureStatus: PermissionStatus = .denied
    
    private init() {
        checkPermissions()
    }
    
    public func checkPermissions() {
        // Accessibility check
        let isAxTrusted = AXIsProcessTrusted()
        accessibilityStatus = isAxTrusted ? .granted : .denied
        
        // Screen recording check
        let isScreenTrusted = CGPreflightScreenCaptureAccess()
        screenCaptureStatus = isScreenTrusted ? .granted : .denied
    }
    
    @discardableResult
    public func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        checkPermissions()
        return trusted
    }
    
    @discardableResult
    public func requestScreenCapture() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        checkPermissions()
        return granted
    }
    
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    public func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
