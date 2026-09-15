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
                Text(artifact.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(artifact.addedBy) · \(artifact.added, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
