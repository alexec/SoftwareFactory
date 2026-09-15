import SwiftUI

/// A document attached to a question, for the person to open before they choose.
struct ReviewLink: View {
    var link: String

    var body: some View {
        if let url = URL(string: link) {
            Link(destination: url) {
                Label(url.host() ?? "Review", systemImage: "arrow.up.right")
            }
            .font(.callout)
            .help(link)
        }
    }
}
