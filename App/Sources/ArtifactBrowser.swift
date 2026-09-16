import SwiftUI
import SoftwareFactoryKit

/// A pile of documents, one on the paper and the rest a tab away.
///
/// It grew on the agent's page and is the same thing a project needs, so it is one view
/// used twice rather than two that drift. The project's documents were a grid of cards
/// you clicked to open a sheet: three steps to read a plan, and a screen of previews of
/// things you had not read. This shows the document. (T342, Alex, 15 Sep 2026.)
///
/// It keeps which one is showing, so give it an `.id` when the pile changes to a
/// different pile, such as going from one agent to the next.
struct ArtifactBrowser: View {
    var documents: [Artifact]
    /// Taking one off, where that is the person's to do. The project's page passes it;
    /// an agent's page does not, because a document is the project's rather than the
    /// agent's to curate. (T266.)
    var onDelete: ((Artifact) -> Void)?

    @State private var reading: UUID?
    /// What this view has already seen, so a document that arrives can be told from one
    /// that was always there. (T315.)
    @State private var seen: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if let showing {
                header(showing)
                Divider()
                ArtifactPaper(artifact: showing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyLine(text: "Nothing has been filed here yet.", symbol: "text.document")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: documents.map(\.id)) { follow() }
        .onAppear { seen = Set(documents.map(\.id)) }
    }

    /// The newest thing written here: what was filed or rewritten last. What the browser
    /// opens on, because news is the reason you looked. (T315.)
    private var newest: Artifact? {
        documents.max { $0.updated < $1.updated }
    }

    /// What was picked, else the newest. Picking one and then watching it be written
    /// over is normal, so a document that has gone falls back rather than leaving the
    /// page blank.
    private var showing: Artifact? {
        documents.first { $0.id == reading } ?? newest ?? documents.first
    }

    /// A document nobody here has seen before takes the paper, whatever was being read.
    /// Only a new one: a status report is written over in place and keeps its id, so the
    /// hourly rewrite does not pull you off a plan you are halfway through.
    private func follow() {
        let ids = Set(documents.map(\.id))
        defer { seen = ids }
        guard !seen.isEmpty else { return }
        guard let newcomer = documents.filter({ !seen.contains($0.id) }).max(by: { $0.added < $1.added })
        else { return }
        reading = newcomer.id
    }

    /// Which document, where it came from, and the way to take it off. One document
    /// needs no tabs, so it does not get any.
    private func header(_ showing: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if documents.count > 1 {
                DocumentTabs(documents: documents, showing: showing.id) { reading = $0 }
            } else {
                Text(showing.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if let label = showing.label {
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color(.faint))
                        .textSelection(.enabled)
                        .help("Its number: say it, type it, or give it to an agent")
                }
                Text("\(showing.kind.title) · \(when(showing), format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(Color(.quiet))
                Spacer(minLength: 0)
                ArtifactSourceLine(artifact: showing)
                if let onDelete {
                    Button("Delete", systemImage: "trash") { onDelete(showing) }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundStyle(Color(.quiet))
                        .help("Take this document off the project. The record is kept, out of the lists.")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// A status report is written over rather than added to, so when it was first filed
    /// says nothing; what matters is when it last changed. (T262.)
    private func when(_ artifact: Artifact) -> Date {
        artifact.kind == .statusReport ? artifact.updated : artifact.added
    }
}

/// The documents across the top of the page they are read on.
///
/// They were a menu, which shows one name and hides the rest behind a click: you could
/// not see that an agent had filed a screenshot without going looking for it. Tabs say
/// what there is. The row scrolls, because twenty documents is the cap and twenty tabs
/// do not fit in any column worth reading in, and the one showing is scrolled to, which
/// matters because a document that arrives takes the paper on its own (T315).
/// (T330, Alex, 15 Sep 2026.)
struct DocumentTabs: View {
    var documents: [Artifact]
    var showing: UUID
    var pick: (UUID) -> Void

    var body: some View {
        ScrollViewReader { row in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(documents) { document in
                        tab(document)
                            .id(document.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .onChange(of: showing) {
                withAnimation(.snappy) { row.scrollTo(showing, anchor: .center) }
            }
        }
    }

    private func tab(_ document: Artifact) -> some View {
        let isShowing = document.id == showing
        return Button { pick(document.id) } label: {
            HStack(spacing: 5) {
                // The same dot the project's cards use for a document nobody has opened.
                // Almost everything here is read the moment the page shows it, so the
                // one that is not is worth a mark. (T335.)
                if !document.isRead {
                    Circle()
                        .fill(.tint)
                        .frame(width: 6, height: 6)
                }
                Image(systemName: symbol(document))
                    .font(.caption)
                Text(document.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.callout)
            // A status report is the one document about the agent rather than about the
            // project, so it is tinted the way its badge already is.
            .foregroundStyle(tint(document, isShowing: isShowing))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: 190)
            .background(
                isShowing ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: .capsule)
        }
        .buttonStyle(.plain)
        .help(document.label.map { "\($0) · \(document.title)" } ?? document.title)
    }

    /// What you will see when you click it: words, a page on the web, a picture, a file.
    /// A brief is what the work is rather than something written down along the way, so
    /// it says so before you open it. (T350.)
    private func symbol(_ document: Artifact) -> String {
        if document.kind == .brief { return "doc.badge.ellipsis" }
        switch document.source {
        case .text: return "doc.plaintext"
        case .web: return "globe"
        case .file(let url): return Artifacts.isPicture(url) ? "photo" : "doc.text"
        }
    }

    private func tint(_ document: Artifact, isShowing: Bool) -> some ShapeStyle {
        if document.kind == .statusReport { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(isShowing ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
}
