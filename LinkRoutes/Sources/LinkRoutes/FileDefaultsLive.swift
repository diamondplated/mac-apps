import AppKit
import UniformTypeIdentifiers

/// The real Launch Services. Used by the app and the settings bridge, never by tests.
struct LaunchServicesFileDefaults: FileDefaultsService {
    private func bundleIdentifier(of url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }

    private func applicationURL(_ identifier: String) -> URL? {
        if identifier == applicationIdentifier {
            let url = Bundle.main.bundleURL
            return url.pathExtension == "app" ? url : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    func typeIdentifier(forExtension ext: String) -> String? {
        guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return nil }
        return type.identifier
    }

    func defaultApplication(forType type: String) -> String? {
        guard let type = UTType(type), let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return bundleIdentifier(of: url)
    }

    func isInstalled(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == applicationIdentifier ? false : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    func candidateApplications(forType type: String) -> [String] {
        guard let type = UTType(type) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type).compactMap(bundleIdentifier(of:))
    }

    func canonicalPath(_ path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
    }

    func setDefaultApplication(_ bundleIdentifier: String, forType type: String) throws {
        guard let type = UTType(type), let url = applicationURL(bundleIdentifier) else { throw RouteError.invalid("The app is unavailable.") }
        final class Box: @unchecked Sendable { let lock = NSLock(); var finished = false; var error: Error? }
        let box = Box()
        NSWorkspace.shared.setDefaultApplication(at: url, toOpen: type) { error in
            box.lock.lock(); box.error = error; box.finished = true; box.lock.unlock()
        }
        // The handler may arrive on any queue, including this one, and macOS may
        // ask the user first; keep the run loop turning while waiting.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            box.lock.lock(); let done = box.finished; box.lock.unlock()
            if done { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            Thread.sleep(forTimeInterval: 0.01)
        }
        box.lock.lock(); let finished = box.finished, error = box.error; box.lock.unlock()
        if !finished { throw RouteError.invalid("macOS did not answer in time.") }
        if let error { throw error }
    }
}
