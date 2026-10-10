import ApplicationServices
import XCTest
@testable import DockPeek

final class TabDiscoveryTests: XCTestCase {
    private struct Node {
        var role: String = "AXGroup"
        var title: String? = nil
        var description: String? = nil
        var selected: Bool? = nil
        var value: Bool? = nil
        var children: [Int] = []
        var tabs: [Int] = []
    }

    private final class Tree: TabTreeReading {
        var nodes: [Int: Node]
        var reads: [(Int, String)] = []
        init(_ nodes: [Int: Node]) { self.nodes = nodes }

        func string(_ attribute: String, of element: Int) -> String? {
            reads.append((element, attribute))
            switch attribute {
            case kAXRoleAttribute: return nodes[element]?.role
            case kAXTitleAttribute: return nodes[element]?.title
            case kAXDescriptionAttribute: return nodes[element]?.description
            default: return nil
            }
        }

        func flag(_ attribute: String, of element: Int) -> Bool? {
            attribute == kAXSelectedAttribute ? nodes[element]?.selected : nodes[element]?.value
        }

        func elements(_ attribute: String, of element: Int) -> [Int] {
            reads.append((element, attribute))
            return (attribute == kAXTabsAttribute ? nodes[element]?.tabs : nodes[element]?.children) ?? []
        }
    }

    func testChromeTabsPreserveOrderDuplicateTitlesAndSelectedValue() {
        let tree = Tree([
            0: Node(role: "AXWindow", children: [1]),
            1: Node(children: [2]),
            2: Node(role: "AXTabGroup", tabs: [3, 4, 5]),
            3: Node(role: "AXRadioButton", title: " Same title ", value: false),
            4: Node(role: "AXRadioButton", title: "Same title", value: true),
            5: Node(role: "AXRadioButton", title: "Grouped tab", value: false)
        ])
        let tabs = TabDiscovery().tabs(in: 0, using: tree)
        XCTAssertEqual(tabs.map(\.element), [3, 4, 5])
        XCTAssertEqual(tabs.map(\.title), ["Same title", "Same title", "Grouped tab"])
        XCTAssertEqual(tabs.map(\.isSelected), [false, true, false])
    }

    func testNativeTabsFallBackToChildrenAndIgnoreNewTabButton() {
        let tree = Tree([
            0: Node(role: "AXWindow", children: [1]),
            1: Node(role: "AXTabGroup", children: [3, 2, 4]),
            2: Node(role: "AXRadioButton", title: "", description: "Document", selected: true),
            3: Node(children: [5]),
            4: Node(role: "AXButton", title: "New tab"),
            5: Node(role: "AXRadioButton")
        ])
        let tabs = TabDiscovery().tabs(in: 0, using: tree)
        XCTAssertEqual(tabs.map(\.title), ["Untitled tab", "Document"])
        XCTAssertTrue(tabs[1].isSelected)
    }

    func testDoesNotReadWebContentOrTreatOrdinaryRadioButtonsAsTabs() {
        let tree = Tree([
            0: Node(role: "AXWindow", children: [1, 2, 3]),
            1: Node(role: "AXWebArea", children: [4]),
            2: Node(role: "AXRadioButton", title: "Preference"),
            3: Node(role: "AXTable", children: [4]),
            4: Node(role: "AXTabGroup", tabs: [5]),
            5: Node(role: "AXRadioButton", title: "Web page tab")
        ])
        XCTAssertTrue(TabDiscovery().tabs(in: 0, using: tree).isEmpty)
        XCTAssertFalse(tree.reads.contains { [1, 3].contains($0.0) && $0.1 == kAXChildrenAttribute })
        XCTAssertFalse(tree.reads.contains { $0.1 == kAXTabsAttribute })
    }

    func testRepeatedElementsAndCyclesDoNotDuplicateTabs() {
        let tree = Tree([
            0: Node(role: "AXWindow", children: [0, 1, 1, 2]),
            1: Node(role: "AXTabGroup", tabs: [3, 3]),
            2: Node(role: "AXTabGroup", tabs: [3, 4]),
            3: Node(role: "AXRadioButton", title: "First"),
            4: Node(role: "AXRadioButton", title: "Second")
        ])
        XCTAssertEqual(TabDiscovery().tabs(in: 0, using: tree).map(\.element), [3, 4])
    }

    func testTraversalIsBoundedForLargeAndDeepTrees() {
        let tree = Tree(Dictionary(uniqueKeysWithValues: (0..<1000).map {
            ($0, Node(children: [$0 + 1]))
        }))
        XCTAssertTrue(TabDiscovery(maximumNodes: 10, maximumDepth: 4).tabs(in: 0, using: tree).isEmpty)
        XCTAssertEqual(tree.reads.filter { $0.1 == kAXRoleAttribute }.count, 5)
        tree.reads.removeAll()
        XCTAssertTrue(TabDiscovery(maximumNodes: 3, maximumDepth: 20).tabs(in: 0, using: tree).isEmpty)
        XCTAssertEqual(tree.reads.filter { $0.1 == kAXRoleAttribute }.count, 3)
    }

    func testExpiredBudgetAndMissingWindowReturnNoTabs() {
        let tree = Tree([:])
        XCTAssertTrue(TabDiscovery(timeBudget: 0).tabs(in: 0, using: tree).isEmpty)
        XCTAssertTrue(tree.reads.isEmpty)
        XCTAssertTrue(TabDiscovery().tabs(in: 0, using: tree).isEmpty)
    }
}
