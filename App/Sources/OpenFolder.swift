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

/// The same button in both places it appears. Nothing is drawn for a project with no
/// folder set: a button that cannot do anything is worse than no button, and the
/// project's header already says how to set one.
struct OpenFolderButton: View {
    var project: Project?

    var body: some View {
        if let url = OpenFolder.url(for: project) {
            Button("Folder", systemImage: "folder") { OpenFolder.open(url) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show \(Projects.shortPath(url.path)) in the Finder")
        }
    }
}
