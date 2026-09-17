import AppKit
import SwiftUI
import SoftwareFactoryKit

/// A project's folder, in the app.
///
/// The folder icon opened the Finder, which is a fine thing to be able to do and the wrong
/// default: you are watching an agent work on a repo, you want to see what is in it, and
/// the answer was to leave the app, land in another one, and come back. The other two icons
/// beside it show what the agent wrote and a shell in the same folder; this is the third way
/// into the same place and now behaves like the other two.
/// (Alex, 16 Sep 2026: make the folder icon show an in-app file browser rather than
/// opening Finder.)
///
/// **It cannot leave the project's folder.** There is no way up past the root, because the
/// root is what the icon is about: an agent works in one folder and this is a look inside
/// it, not a file manager. The Finder is still one click away for everything else.
struct FileBrowser: View {
    var root: URL

    @State private var folder: URL
    @State private var showing: URL?
    @State private var trouble: String?

    init(root: URL) {
        self.root = root
        _folder = State(initialValue: root)
    }

    var body: some View {
        VStack(spacing: 0) {
            crumbs
            Divider()
            if let showing {
                file(showing)
            } else {
                listing
            }
        }
        // Somebody else's folder, or the same one from a different agent: back to the top
        // rather than showing a path that is not under this root any more.
        .onChange(of: root) { _, now in
            folder = now
            showing = nil
            trouble = nil
        }
    }

    // MARK: Where you are

    /// The path from the project's folder down, each part a way back to it. The root is
    /// named rather than shown as its full path: you know which project you are in, and the
    /// interesting half of a long path is the end.
    private var crumbs: some View {
        HStack(spacing: 4) {
            if showing != nil {
                Button("Back", systemImage: "chevron.left") { showing = nil }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("Back to \(folder.lastPathComponent)")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 {
                            Text("/").font(Style.Text.quiet).foregroundStyle(.tertiary)
                        }
                        Button(part.name) {
                            folder = part.url
                            showing = nil
                        }
                        .buttonStyle(.plain)
                        .font(Style.Text.quiet)
                        .foregroundStyle(index == parts.count - 1 && showing == nil
                                         ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    }
                    if let showing {
                        Text("/").font(Style.Text.quiet).foregroundStyle(.tertiary)
                        Text(showing.lastPathComponent)
                            .font(Style.Text.quiet)
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 4)
            Button("Finder", systemImage: "arrow.up.forward.app") {
                OpenFolder.open(showing ?? folder)
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .help("Show it in the Finder")
        }
        .padding(.horizontal, Style.cardPadding)
        .padding(.vertical, 6)
    }

    private struct Crumb {
        var name: String
        var url: URL
    }

    /// The root, then every folder below it that you are inside. Built by walking down from
    /// the root rather than up from here, so a folder that is somehow not under the root
    /// cannot put a way out of it on the bar.
    private var parts: [Crumb] {
        var out = [Crumb(name: root.lastPathComponent, url: root)]
        let rootParts = root.standardizedFileURL.pathComponents
        let here = folder.standardizedFileURL.pathComponents
        guard here.count > rootParts.count, Array(here.prefix(rootParts.count)) == rootParts else {
            return out
        }
        var walking = root
        for name in here.dropFirst(rootParts.count) {
            walking = walking.appending(path: name)
            out.append(Crumb(name: name, url: walking))
        }
        return out
    }

    // MARK: What is in it

    private var listing: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let trouble {
                    EmptyLine(text: trouble, symbol: "questionmark.folder")
                        .padding(Style.cardPadding)
                } else if contents.isEmpty {
                    EmptyLine(text: "Nothing in here.", symbol: "folder")
                        .padding(Style.cardPadding)
                }
                ForEach(contents, id: \.self) { url in
                    Button {
                        if isFolder(url) { folder = url } else { showing = url }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: symbol(for: url))
                                .font(.callout)
                                .foregroundStyle(isFolder(url) ? AnyShapeStyle(.tint)
                                                               : AnyShapeStyle(.secondary))
                                .frame(width: 18)
                            Text(url.lastPathComponent)
                                .font(Style.Text.row)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if isFolder(url) {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, Style.cardPadding)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Folders first, then files, each in the order a person reads them. Case insensitive,
    /// because a folder called Sources and one called app are not in two different alphabets.
    private var contents: [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return found.sorted { a, b in
            let fa = isFolder(a), fb = isFolder(b)
            if fa != fb { return fa }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// What a file looks like before you open it. Off the extension, because that is what
    /// the person is reading anyway.
    private func symbol(for url: URL) -> String {
        if isFolder(url) { return "folder.fill" }
        let kind = url.pathExtension.lowercased()
        if Artifacts.isPicture(url) { return kind == "pdf" ? "doc.richtext" : "photo" }
        if Artifacts.readableFiles.contains(kind) { return "doc.text" }
        if Self.code.contains(kind) { return "chevron.left.forwardslash.chevron.right" }
        return "doc"
    }

    private static let code: Set<String> = [
        "swift", "m", "h", "c", "cpp", "js", "ts", "py", "rb", "sh", "zsh", "json", "yml",
        "yaml", "toml", "plist", "xml", "css", "rs", "go", "java", "kt",
    ]

    // MARK: One file

    /// The same web view a document is read in, so a markdown file in the repo comes out as
    /// a page and a screenshot comes out as a screenshot, exactly as a filed one does.
    /// Anything else readable is shown as what it is: text in the machine's own face, with
    /// no attempt to make a source file look like prose.
    @ViewBuilder
    private func file(_ url: URL) -> some View {
        let kind = url.pathExtension.lowercased()
        if Artifacts.isPicture(url) || kind == "html" || kind == "htm" {
            PaperView(page: .file(url))
        } else if Artifacts.readableFiles.contains(kind) {
            PaperView(page: .html(Paper.page(markdown: (try? String(contentsOf: url, encoding: .utf8)) ?? "",
                                             title: url.lastPathComponent),
                                  base: url.deletingLastPathComponent()))
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(Style.Text.machine)
                    .textSelection(.enabled)
                    .padding(Style.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Not text and not a picture. Saying so beats an empty pane, and the Finder
            // button above still opens it in whatever does know what it is.
            EmptyLine(text: "\(url.lastPathComponent) is not something this can show.",
                      symbol: "doc.questionmark")
                .padding(Style.cardPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
