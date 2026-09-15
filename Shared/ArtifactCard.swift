import SwiftUI
import SoftwareFactoryKit

/// A document on a project: its title, and the body once you open it.
///
/// `onDelete` is how a page says the person may take this one off. The project's page
/// passes it, because that is where the project's documents are curated; every other
/// place the card appears (an agent's page, a question that names a document to read)
/// leaves it out, and the card shows no way to delete one. (T266.)
struct ArtifactCard: View {
    var artifact: Artifact
    var onDelete: (() -> Void)?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !artifact.body.isEmpty {
                    MarkdownText(text: artifact.body)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if !artifact.link.isEmpty {
                    ReviewLink(link: artifact.link)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(artifact.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if artifact.kind == .statusReport { kindBadge }
                    }
                    // A status report is written over rather than added to, so when it
                    // was first filed says nothing. What matters is when it last changed:
                    // that is how you tell a current picture from one from this morning.
                    // (T262.)
                    Text("\(artifact.addedBy) · \(when, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let onDelete { deleteButton(onDelete) }
            }
        }
        .contextMenu {
            if let onDelete {
                Button("Delete document", role: .destructive, action: onDelete)
            }
        }
    }

    /// Small, quiet, and to the side: taking a document off is something you do now and
    /// then, and it sits next to the title rather than in front of it.
    private func deleteButton(_ delete: @escaping () -> Void) -> some View {
        Button("Delete", systemImage: "trash", action: delete)
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Take this document off the project. The record is kept, out of the lists.")
    }

    private var when: Date {
        artifact.kind == .statusReport ? artifact.updated : artifact.added
    }

    private var kindBadge: some View {
        Text(artifact.kind.title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: .capsule)
            .foregroundStyle(.tint)
    }
}
