import Foundation

public enum MenuKind: Equatable {
    case items       // right-click on selected items
    case container   // right-click on a folder's background
    case toolbar     // the Finder toolbar button
    case sidebar     // right-click in the sidebar: nothing is added
}

public enum MenuEntry: Equatable {
    case newFile(extensions: [String])
    case openTerminal
    case copyPath

    public var title: String {
        switch self {
        case .newFile: return "New File"
        case .openTerminal: return "Open Terminal Here"
        case .copyPath: return "Copy Path"
        }
    }
}

public enum MenuModel {
    /// What to add to a Finder menu: only the switched-on items, in a fixed order.
    public static func entries(settings: RightHereSettings, kind: MenuKind) -> [MenuEntry] {
        if kind == .sidebar { return [] }
        var result: [MenuEntry] = []
        if settings.showsNewFile { result.append(.newFile(extensions: settings.newFileExtensions)) }
        if settings.showsOpenTerminal { result.append(.openTerminal) }
        if settings.showsCopyPath { result.append(.copyPath) }
        return result
    }

    /// "Text File", "Markdown File", otherwise "<EXT> File".
    public static func fileTitle(forExtension ext: String) -> String {
        switch ext {
        case "txt": return "Text File"
        case "md": return "Markdown File"
        default: return "\(ext.uppercased()) File"
        }
    }
}

/// Where each action applies, from Finder's selection and the folder it is showing.
public enum Target {
    /// The folder that holds every item, when they all share one; nil otherwise.
    private static func commonParent(_ selection: [URL]) -> URL? {
        let parents = Set(selection.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard parents.count == 1, let path = parents.first else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// New File goes beside the selection (in the folder they share), or in the folder Finder is
    /// showing when nothing is selected or the items live in different folders.
    public static func newFileFolder(selection: [URL], targeted: URL?) -> URL? {
        if selection.isEmpty { return targeted }
        return commonParent(selection) ?? targeted
    }

    /// Open Terminal Here opens a single selected folder itself; otherwise the same folder New File uses.
    public static func terminalFolder(selection: [URL], targeted: URL?, isDirectory: (URL) -> Bool) -> URL? {
        if selection.count == 1, let only = selection.first, isDirectory(only) { return only }
        return newFileFolder(selection: selection, targeted: targeted)
    }
}

public enum CopyPath {
    /// One POSIX path per line, or the folder's path when nothing is selected.
    public static func text(selection: [URL], targeted: URL?) -> String? {
        if !selection.isEmpty { return selection.map { $0.path }.joined(separator: "\n") }
        return targeted?.path
    }
}
