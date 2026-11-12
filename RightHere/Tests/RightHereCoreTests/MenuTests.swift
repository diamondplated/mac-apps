import XCTest
@testable import RightHereCore

final class MenuTests: XCTestCase {
    private func settings(_ n: Bool, _ t: Bool, _ c: Bool) -> RightHereSettings {
        var s = RightHereSettings(); s.showsNewFile = n; s.showsOpenTerminal = t; s.showsCopyPath = c; return s
    }

    func testEveryCombinationOfSwitchesForEveryMenuKind() {
        for bits in 0..<8 {
            let n = bits & 1 != 0, t = bits & 2 != 0, c = bits & 4 != 0
            var expected: [MenuEntry] = []
            if n { expected.append(.newFile(extensions: ["txt", "md"])) }
            if t { expected.append(.openTerminal) }
            if c { expected.append(.copyPath) }
            for kind in [MenuKind.items, .container, .toolbar] {
                XCTAssertEqual(MenuModel.entries(settings: settings(n, t, c), kind: kind), expected, "bits \(bits) \(kind)")
            }
            XCTAssertEqual(MenuModel.entries(settings: settings(n, t, c), kind: .sidebar), [], "the sidebar gets nothing")
        }
    }

    func testNewFileEntryCarriesConfiguredExtensions() {
        var s = RightHereSettings(); s.newFileExtensions = ["py", "html"]
        XCTAssertEqual(MenuModel.entries(settings: s, kind: .container).first, .newFile(extensions: ["py", "html"]))
    }

    func testTitles() {
        XCTAssertEqual(MenuModel.fileTitle(forExtension: "txt"), "Text File")
        XCTAssertEqual(MenuModel.fileTitle(forExtension: "md"), "Markdown File")
        XCTAssertEqual(MenuModel.fileTitle(forExtension: "py"), "PY File")
        XCTAssertEqual(MenuEntry.newFile(extensions: []).title, "New File")
        XCTAssertEqual(MenuEntry.openTerminal.title, "Open Terminal Here")
        XCTAssertEqual(MenuEntry.copyPath.title, "Copy Path")
    }

    func testTargetFolders() {
        let window = URL(fileURLWithPath: "/Users/x/Desktop", isDirectory: true)
        let file = URL(fileURLWithPath: "/Users/x/Desktop/note.txt")
        let folder = URL(fileURLWithPath: "/Users/x/Desktop/Projects", isDirectory: true)
        let other = URL(fileURLWithPath: "/Users/x/Documents/a.pdf")
        let isDir: (URL) -> Bool = { $0 == folder }
        // Nothing selected: the folder Finder is showing, for both actions.
        XCTAssertEqual(Target.newFileFolder(selection: [], targeted: window), window)
        XCTAssertEqual(Target.terminalFolder(selection: [], targeted: window, isDirectory: isDir), window)
        // A selected file: its folder.
        XCTAssertEqual(Target.newFileFolder(selection: [file], targeted: nil)?.path, "/Users/x/Desktop")
        XCTAssertEqual(Target.terminalFolder(selection: [file], targeted: nil, isDirectory: isDir)?.path, "/Users/x/Desktop")
        // A selected folder: New File lands beside it, the terminal opens it.
        XCTAssertEqual(Target.newFileFolder(selection: [folder], targeted: window)?.path, "/Users/x/Desktop")
        XCTAssertEqual(Target.terminalFolder(selection: [folder], targeted: window, isDirectory: isDir)?.path, "/Users/x/Desktop/Projects")
        // Several items in one folder share it; in different folders, the folder Finder shows.
        XCTAssertEqual(Target.newFileFolder(selection: [file, folder], targeted: window)?.path, "/Users/x/Desktop")
        XCTAssertEqual(Target.terminalFolder(selection: [file, folder], targeted: window, isDirectory: isDir)?.path, "/Users/x/Desktop")
        XCTAssertEqual(Target.newFileFolder(selection: [file, other], targeted: window), window)
        XCTAssertNil(Target.newFileFolder(selection: [file, other], targeted: nil))
        XCTAssertNil(Target.terminalFolder(selection: [], targeted: nil, isDirectory: isDir))
    }

    func testCopyPath() {
        let a = URL(fileURLWithPath: "/Users/x/My Folder/a b.txt")
        let b = URL(fileURLWithPath: "/Users/x/c.md")
        XCTAssertEqual(CopyPath.text(selection: [a, b], targeted: URL(fileURLWithPath: "/ignored")), "/Users/x/My Folder/a b.txt\n/Users/x/c.md")
        XCTAssertEqual(CopyPath.text(selection: [], targeted: URL(fileURLWithPath: "/Users/x/Desktop", isDirectory: true)), "/Users/x/Desktop")
        XCTAssertNil(CopyPath.text(selection: [], targeted: nil))
    }
}
