import ApplicationServices
import Foundation

public struct TabInfo: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let title: String
    public let fullTitle: String
    public let isSelected: Bool
    public let axElement: AXUIElement?

    public init(id: UUID = UUID(), title: String, fullTitle: String? = nil, isSelected: Bool, axElement: AXUIElement?) {
        self.id = id
        self.title = title
        self.fullTitle = fullTitle ?? title
        self.isSelected = isSelected
        self.axElement = axElement
    }
}

enum TabTitleFormatter {
    static func displayTitle(_ title: String, bundleIdentifier: String?) -> String {
        let chromiumApps = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser"]
        guard let bundleIdentifier,
              chromiumApps.contains(where: { bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".") }) else { return title }
        // Chrome appends screen-reader status to AXTitle instead of providing
        // a separate description. Keep the full label in tooltips/VoiceOver.
        let clean = title
            .replacingOccurrences(of: #" - (?:High )?[Mm]emory usage - [0-9][0-9.,\s]*[KMGT]?B$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" - Part of group .+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? title : clean
    }
}

// Keep traversal separate from AX messaging so unusual trees can be regression tested.
protocol TabTreeReading {
    associatedtype Element: Hashable
    func string(_ attribute: String, of element: Element) -> String?
    func flag(_ attribute: String, of element: Element) -> Bool?
    func elements(_ attribute: String, of element: Element) -> [Element]
}

struct DiscoveredTab<Element> {
    let element: Element
    let title: String
    let isSelected: Bool
}

struct TabDiscovery {
    var maximumNodes = 512
    var maximumDepth = 12
    var timeBudget: TimeInterval = 0.5

    func tabs<Reader: TabTreeReading>(in window: Reader.Element, using reader: Reader) -> [DiscoveredTab<Reader.Element>] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        var stack: [(Reader.Element, Int, Bool)] = [(window, 0, false)]
        var visited = Set<Reader.Element>()
        var tabElements = Set<Reader.Element>()
        var result: [DiscoveredTab<Reader.Element>] = []
        var scheduledNodes = 1

        func appendTab(_ element: Reader.Element) {
            guard tabElements.insert(element).inserted else { return }
            let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .lazy.compactMap { reader.string($0, of: element)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Untitled tab"
            result.append(DiscoveredTab(
                element: element, title: title,
                isSelected: reader.flag(kAXSelectedAttribute, of: element)
                    ?? reader.flag(kAXValueAttribute, of: element) ?? false
            ))
        }

        while !stack.isEmpty && visited.count < maximumNodes && ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth, insideTabGroup) = stack.removeLast()
            guard visited.insert(element).inserted else { continue }
            let role = reader.string(kAXRoleAttribute, of: element) ?? ""
            // Never search document content, web ARIA tabs, or large data views.
            guard !["AXWebArea", "AXTextArea", "AXTable", "AXOutline"].contains(role) else { continue }

            if insideTabGroup && [kAXRadioButtonRole, "AXTab"].contains(role) {
                appendTab(element)
                continue
            }
            let isTabGroup = role == kAXTabGroupRole
            if isTabGroup {
                // AXTabs is authoritative and includes tabs in Chrome tab groups.
                // Query it only on tab groups: some apps implement it recursively.
                let tabs = reader.elements(kAXTabsAttribute, of: element)
                if !tabs.isEmpty {
                    for tab in tabs.prefix(maximumNodes) {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                        appendTab(tab)
                    }
                    continue
                }
            }
            guard depth < maximumDepth else { continue }
            let remaining = max(0, maximumNodes - scheduledNodes)
            let children = reader.elements(kAXChildrenAttribute, of: element).prefix(remaining)
            scheduledNodes += children.count
            // Depth-first order preserves the strip's order even with nested groups.
            stack.append(contentsOf: children.reversed().map {
                ($0, depth + 1, insideTabGroup || isTabGroup)
            })
        }
        return result
    }
}

private struct AXTabTreeReader: TabTreeReading {
    private func value(_ attribute: String, of element: AXUIElement) -> AnyObject? {
        // A nonresponsive app must not hold up hover previews indefinitely.
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String, of element: AXUIElement) -> String? {
        value(attribute, of: element) as? String
    }

    func flag(_ attribute: String, of element: AXUIElement) -> Bool? {
        (value(attribute, of: element) as? NSNumber)?.boolValue
    }

    func elements(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, 512, &values) == .success else { return [] }
        return values as? [AXUIElement] ?? []
    }
}

enum TabService {
    static func tabs(in window: AXUIElement, bundleIdentifier: String? = nil) -> [TabInfo] {
        TabDiscovery().tabs(in: window, using: AXTabTreeReader()).map {
            TabInfo(title: TabTitleFormatter.displayTitle($0.title, bundleIdentifier: bundleIdentifier), fullTitle: $0.title, isSelected: $0.isSelected, axElement: $0.element)
        }
    }

    @discardableResult
    static func select(_ tab: TabInfo) -> Bool {
        guard let element = tab.axElement else { return false }
        AXUIElementSetMessagingTimeout(element, 0.2)
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
        // Native tab controls and Chromium also support selecting via AXValue.
        for attribute in [kAXValueAttribute, kAXSelectedAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
               settable.boolValue,
               AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue) == .success {
                return true
            }
        }
        return false
    }
}
