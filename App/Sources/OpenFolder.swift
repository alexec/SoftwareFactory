import AppKit
import SwiftUI
import SoftwareFactoryKit

/// Opening a project's folder in the Finder, from wherever the person is standing.
///
/// The factory knows where every project's work lives, and the person was going to the
/// Finder to find the same folder by hand. (T300, Alex, 15 Sep 2026.)
enum OpenFolder {
    /// Whether there is a folder to open at all. A project with none has nothing here.
    static func url(for project: Project?) -> URL? {
        Projects.folder(project?.path)
    }

    /// The Finder, with the folder itself selected rather than opened into: it is a
    /// place, and the person is usually about to drag something to it or look next to it.
    static func open(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// `OpenFolderButton` stood here: the folder icon above an agent's side column, which opened
// the Finder. The icon is still there and opens `FileBrowser` in the column beside the
// agent instead, because leaving the app to see what is in a repo you are watching an agent
// work on is a poor default. `OpenFolder.open` is what the browser's own Finder button
// calls, and what everything else that really wants the Finder calls.
// (Alex, 16 Sep 2026: make the folder icon show an in-app file browser rather than opening
// Finder.)
