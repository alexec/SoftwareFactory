import SwiftUI
import SoftwareFactoryKit

/// A project's document on the front of a card: what it is, who filed it, when, and
/// enough of what it says to tell it from the one next to it. Clicking opens it whole.
///
/// They were disclosure rows down the middle of the backlog, which made a plan and a
/// one-line note the same size and hid every one of them behind a triangle. A project's
/// documents are the reading the person does before they decide anything, so they get the
/// shape the rest of the floor uses. (T297, Alex, 15 Sep 2026.)
struct ArtifactTile: View {
    var artifact: Artifact
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(artifact.kind.title)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: .capsule)
                        .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                    if !artifact.link.isEmpty {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(artifact.link)
                    }
                }
                Text(artifact.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // The document in a sentence or two, marks off. A card is not the place
                // to read markdown.
                Text(Markdown.summary(artifact.body, limit: 160))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text("\(artifact.addedBy) · \(when, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(height: 168, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .help("Open \(artifact.title)")
    }

    /// A status report is written over rather than added to, so when it was first filed
    /// says nothing. What matters is when it last changed. (T262.)
    private var when: Date {
        artifact.kind == .statusReport ? artifact.updated : artifact.added
    }
}

/// One document, whole, with its link and the way to take it off the project.
struct ArtifactSheet: View {
    var artifact: Artifact
    var onDelete: (() -> Void)?
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(artifact.kind.title) · \(artifact.addedBy) · \(when, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Done", action: close)
                    .buttonStyle(.glassProminent)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if artifact.body.isEmpty {
                        Text("Nothing was written in it.")
                            .foregroundStyle(.secondary)
                    } else {
                        MarkdownText(text: artifact.body)
                            .textSelection(.enabled)
                    }
                    if !artifact.link.isEmpty {
                        ReviewLink(link: artifact.link)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onDelete {
                Divider()
                HStack {
                    Spacer()
                    Button("Delete document", role: .destructive) {
                        onDelete()
                        close()
                    }
                    .help("Take this document off the project. The record is kept, out of the lists.")
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 520)
    }

    private var when: Date {
        artifact.kind == .statusReport ? artifact.updated : artifact.added
    }
}
