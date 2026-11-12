import Cocoa
import FinderSync
import RightHereCore

/// The Finder Sync extension. Every decision lives in RightHereCore; this class reads Finder's
/// selection, builds the menu, and hands the result to AppKit. It observes no folder badges and
/// does nothing in the observation callbacks. The principal class named in the extension's Info.plist.
@objc(RightHereFinderSync)
final class RightHereFinderSync: FIFinderSync {
    /// The extensions offered by the menu last built; a submenu item's tag indexes into this.
    private var offeredExtensions: [String] = []

    override init() {
        super.init()
        // Register for "/" so the items appear everywhere Finder allows.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: Toolbar button

    override var toolbarItemName: String { "RightHere" }
    override var toolbarItemToolTip: String { "New File, Open Terminal Here and Copy Path" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: "RightHere") ?? NSImage()
    }

    // MARK: Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let kind: MenuKind
        switch menuKind {
        case .contextualMenuForItems: kind = .items
        case .contextualMenuForContainer: kind = .container
        case .toolbarItemMenu: kind = .toolbar
        default: kind = .sidebar
        }
        // Read at each menu build, so a change in Mac Tools shows up the next time a menu opens.
        let defaults = UserDefaults(suiteName: RightHereSettings.domain)
        let settings = defaults.map { SettingsStore(defaults: $0).settings } ?? RightHereSettings()
        for entry in MenuModel.entries(settings: settings, kind: kind) {
            switch entry {
            case .newFile(let extensions):
                offeredExtensions = extensions
                let submenu = NSMenu(title: entry.title)
                for (index, ext) in extensions.enumerated() {
                    let item = NSMenuItem(title: MenuModel.fileTitle(forExtension: ext), action: #selector(newFile(_:)), keyEquivalent: "")
                    item.tag = index
                    item.target = self
                    submenu.addItem(item)
                }
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)
            case .openTerminal:
                let item = NSMenuItem(title: entry.title, action: #selector(openTerminal(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            case .copyPath:
                let item = NSMenuItem(title: entry.title, action: #selector(copyPath(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        return menu
    }

    // MARK: Actions

    private var selection: [URL] { FIFinderSyncController.default().selectedItemURLs() ?? [] }
    private var targeted: URL? { FIFinderSyncController.default().targetedURL() }

    @objc private func newFile(_ sender: NSMenuItem) {
        guard offeredExtensions.indices.contains(sender.tag),
              let folder = Target.newFileFolder(selection: selection, targeted: targeted) else { NSSound.beep(); return }
        do {
            let created = try NewFile.create(in: folder, ext: offeredExtensions[sender.tag])
            NSWorkspace.shared.activateFileViewerSelecting([created])
        } catch {
            NSSound.beep()
            NSLog("RightHere could not create a file: \(error.localizedDescription)")
        }
    }

    @objc private func openTerminal(_ sender: NSMenuItem) {
        let isDirectory: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard let folder = Target.terminalFolder(selection: selection, targeted: targeted, isDirectory: isDirectory) else { NSSound.beep(); return }
        let defaults = UserDefaults(suiteName: RightHereSettings.domain)
        let saved = defaults.map { SettingsStore(defaults: $0).settings.terminalBundleIdentifier } ?? Terminal.fallbackIdentifier
        let available = Terminal.available { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        let identifier = Terminal.resolve(saved: saved, available: available).identifier
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { NSSound.beep(); return }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let text = CopyPath.text(selection: selection, targeted: targeted) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
