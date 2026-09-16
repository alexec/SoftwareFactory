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

/// Nothing is drawn for a project with no folder set: a button that cannot do anything is
/// worse than no button, and the project's header already says how to set one.
///
/// It sits in the row of small icons above an agent's side column, beside the one that
/// opens a shell. It was up in the header next to the project's name, where it was a
/// word and an icon among words: the Finder, a shell and the agent's own documents are
/// three ways into the same folder, so they are one set of icons in one place rather than
/// one of them sitting apart from the other two. (Alex, 15 Sep 2026.)
struct OpenFolderButton: View {
    var project: Project?

    var body: some View {
        if let url = OpenFolder.url(for: project) {
            Button { OpenFolder.open(url) } label: {
                Image(systemName: "folder")
                    .font(.callout)
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show \(Projects.shortPath(url.path)) in the Finder")
        }
    }
}
