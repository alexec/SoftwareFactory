import SwiftUI
import WebKit
import SoftwareFactoryKit

/// A document, read. Whatever it is made of, it arrives here as a page on paper: an
/// agent's markdown turned into HTML, a markdown file out of the repo turned into the
/// same HTML, a website as itself.
///
/// One renderer for all three, because the person opening a document does not care which
/// of them it was. It also settles what markdown looks like: headings, lists and code
/// were being rebuilt out of text views, one block at a time, and a web view already
/// knows how to lay out a document. (T311, Alex, 15 Sep 2026.)
struct ArtifactPaper: View {
    @Environment(AppModel.self) private var model
    var artifact: Artifact

    @State private var page: PaperPage?
    @State private var trouble: String?

    var body: some View {
        Group {
            if let trouble {
                VStack {
                    EmptyLine(text: trouble, symbol: "questionmark.folder")
                        .padding(20)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let page {
                PaperView(page: page)
            } else {
                Color.clear
            }
        }
        // The body and the link both change what is on the page, and a status report is
        // written over in place, so the date it last changed is part of the question too.
        .task(id: "\(artifact.id)\(artifact.link)\(artifact.updated.timeIntervalSince1970)") {
            // On the page is read. This is the only place a document is shown whole, on
            // the agent's paper and in the project's sheet alike, so it is the only place
            // that has to say so. (T335.)
            model.markRead(artifact)
            await read()
        }
    }

    private func read() async {
        trouble = nil
        switch artifact.source {
        case .text:
            guard !artifact.body.isEmpty else {
                page = nil
                trouble = "Nothing was written in it."
                return
            }
            page = .html(Paper.page(markdown: artifact.body, title: artifact.title), base: nil)
        case .web(let url):
            page = .web(url)
        case .file(let url):
            let kind = url.pathExtension.lowercased()
            // An HTML file is loaded from where it sits so its own stylesheet loads with
            // it. A picture is shown as itself: a screenshot on a sheet of paper with
            // margins is a screenshot you can see less of, and WebKit's own image view
            // already scales it to the column and lets you zoom. (T317.)
            if kind == "html" || kind == "htm" || Artifacts.isPicture(url) {
                page = .file(url)
                return
            }
            // Off the main thread: the file may be on a disk that has to spin up, or a
            // share that has to answer, and the window stays live while it does.
            let text = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
            guard let text else {
                page = nil
                trouble = "That file could not be read: \(Projects.shortPath(url.path))"
                return
            }

            // The folder it came from is the base, so an image or a link written next to
            // it in the repo still points at the right thing.
            page = .html(Paper.page(markdown: text, title: artifact.title),
                         base: url.deletingLastPathComponent())
        }
    }
}

/// What a web view has been asked to show. The three ways a document arrives.
enum PaperPage: Equatable {
    /// HTML this app made, with the folder relative links should be read against.
    case html(String, base: URL?)
    case web(URL)
    /// An HTML file on disk, loaded from where it sits so its own stylesheet loads too.
    case file(URL)
}

/// The web view itself. Nothing is stored, nothing goes back or forward, and a link the
/// person clicks opens in their browser rather than taking the pane somewhere else: this
/// is a page to read, not a place to browse from.
struct PaperView: NSViewRepresentable {
    var page: PaperPage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        load(page, into: web, context.coordinator)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.showing != page else { return }
        load(page, into: web, context.coordinator)
    }

    private func load(_ page: PaperPage, into web: WKWebView, _ coordinator: Coordinator) {
        coordinator.showing = page
        switch page {
        case .html(let html, let base):
            // Script in a document an agent wrote is not something anybody asked for.
            coordinator.allowsScript = false
            web.loadHTMLString(html, baseURL: base)
        case .web(let url):
            // A site that needs script to show its words is most sites.
            coordinator.allowsScript = true
            web.load(URLRequest(url: url))
        case .file(let url):
            coordinator.allowsScript = false
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var showing: PaperPage?
        var allowsScript = false

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            preferences.allowsContentJavaScript = allowsScript
            // Everything the person clicks goes to their browser. The pane shows the one
            // document it was given, so a link cannot leave you somewhere else with no
            // way back.
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel, preferences)
                return
            }
            decisionHandler(.allow, preferences)
        }
    }
}

/// Where a document came from, said in a few words beside it. A document an agent typed
/// came from nowhere else, so nothing is drawn for it: the page is the document.
struct ArtifactSourceLine: View {
    var artifact: Artifact

    var body: some View {
        switch artifact.source {
        case .text:
            EmptyView()
        case .web(let url):
            Link(destination: url) {
                Label(url.host() ?? "Open", systemImage: "arrow.up.right")
            }
            .font(.caption)
            .help("Open \(artifact.link) in your browser")
        case .file(let url):
            Button(url.lastPathComponent, systemImage: Artifacts.isPicture(url) ? "photo" : "doc") {
                OpenFolder.open(url)
            }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Show \(Projects.shortPath(url.path)) in the Finder")
        }
    }
}
