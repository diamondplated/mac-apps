import Foundation

/// Picks the running app a Dock item stands for, by bundle URL and then by exact name.
/// Partial names are never matched: "Xcode" contains "Code" (VS Code's process name).
enum DockItemMatcher {
    struct Candidate {
        let name: String?
        let bundleURL: URL?
    }

    static func index(title: String, url: URL?, in candidates: [Candidate]) -> Int? {
        if let url, let match = candidates.firstIndex(where: { $0.bundleURL == url }) {
            return match
        }
        guard !title.isEmpty else { return nil }
        return candidates.firstIndex(where: { $0.name?.caseInsensitiveCompare(title) == .orderedSame })
    }
}
