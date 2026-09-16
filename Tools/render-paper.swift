import Foundation

/// A markdown file in `design/` as a page on paper, set in the house theme.
///
/// The rendering is `Paper`, all of it, and nothing here has a copy of it: a document an
/// agent filed, a page in the repo and a brief are one renderer, so the theme cannot drift
/// between them. It had a table parser of its own for as long as the kit had none, which
/// was three hours. (T391.)
///
/// The one thing it adds is a swatch: a cell holding a six-digit hex is drawn with that
/// colour in front of it, which is what a palette written as a table is trying to say.
///
///     swiftc -O Tools/render-paper.swift \
///       Packages/SoftwareFactoryKit/Sources/SoftwareFactoryKit/Paper.swift \
///       Packages/SoftwareFactoryKit/Sources/SoftwareFactoryKit/Markdown.swift \
///       -o /tmp/render-paper
///     /tmp/render-paper design/ux-brief.md design/ux-brief.html "The UX brief"
@main
struct RenderPaper {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("render-paper <in.md> <out.html> [title]\n".utf8))
            exit(2)
        }
        let markdown = try String(contentsOfFile: args[1], encoding: .utf8)
        let title = args.count > 3 ? args[3] : ""
        let page = swatched(Paper.page(markdown: markdown, title: title))
        try page.write(toFile: args[2], atomically: true, encoding: .utf8)
    }

    /// Every cell that is nothing but a colour, with the colour put in front of it.
    static func swatched(_ html: String) -> String {
        var out = html
        var from = out.startIndex
        while let cell = out.range(of: "<td><code>[0-9a-fA-F]{6}</code></td>",
                                  options: .regularExpression,
                                  range: from..<out.endIndex) {
            let hex = out[cell].dropFirst("<td><code>".count).prefix(6)
            let replacement = "<td>\(swatch(String(hex)))<code>\(hex)</code></td>"
            out.replaceSubrange(cell, with: replacement)
            from = out.index(cell.lowerBound, offsetBy: replacement.count)
        }
        return out
    }

    static func swatch(_ hex: String) -> String {
        "<span style=\"display: inline-block; width: 0.8em; height: 0.8em; border-radius: 2px; "
            + "border: 1px solid var(--edge); background: #\(hex); vertical-align: -0.05em; "
            + "margin-right: 0.45em;\"></span>"
    }
}
