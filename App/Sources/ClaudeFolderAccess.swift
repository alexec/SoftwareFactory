import AppKit
import ForemanKit

/// The one folder outside the sandbox the app reads: Claude Code's own, `~/.claude`.
/// The person picks it once; a security-scoped bookmark remembers it.
@Observable
@MainActor
final class ClaudeFolderAccess {
    private(set) var url: URL?

    static let bookmarkKey = "claudeFolderBookmark"

    init() {
        url = Self.restore()
    }

    var isGranted: Bool { url != nil }

    /// Opens the folder chooser, already pointed at `~/.claude`.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = ClaudeCodeScanner.defaultRoot()
        panel.message = "Choose the .claude folder in your home folder."
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            let bookmark = try chosen.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            url = chosen
        } catch {
            url = nil
        }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        url = nil
    }

    private static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale, let fresh = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }
}
