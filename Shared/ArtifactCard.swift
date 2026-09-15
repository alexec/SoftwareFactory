import SwiftUI
import SoftwareFactoryKit

/// A document on a project: its title, and the body once you open it.
struct ArtifactCard: View {
    var artifact: Artifact

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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(artifact.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if artifact.kind == .statusReport { kindBadge }
                }
                // A status report is written over rather than added to, so when it was
                // first filed says nothing. What matters is when it last changed: that
                // is how you tell a current picture from one from this morning. (T262.)
                Text("\(artifact.addedBy) · \(when, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
