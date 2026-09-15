import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct MarkdownTests {
    @Test func headingsParagraphsAndRules() {
        let blocks = Markdown.blocks("""
        # The iPad app

        The floor on a big screen
        you can pick up.

        ---

        ## What it is
        """)
        #expect(blocks == [
            .heading(level: 1, text: "The iPad app"),
            .paragraph("The floor on a big screen you can pick up."),
            .rule,
            .heading(level: 2, text: "What it is"),
        ])
    }

    @Test func listsKeepTheirMarksAndIndent() {
        let blocks = Markdown.blocks("""
        - No terminal.
          - Not even a read-only one.
        * Also a bullet
        1. First
        2) Second
        """)
        #expect(blocks == [
            .bullet(text: "No terminal.", indent: 0),
            .bullet(text: "Not even a read-only one.", indent: 1),
            .bullet(text: "Also a bullet", indent: 0),
            .numbered(number: 1, text: "First"),
            .numbered(number: 2, text: "Second"),
        ])
    }

    @Test func fencedCodeIsKeptLineForLine() {
        let blocks = Markdown.blocks("""
        Run it:

        ```bash
        cd Packages/SoftwareFactoryKit
          swift test
        ```

        Done.
        """)
        #expect(blocks == [
            .paragraph("Run it:"),
            .code(["cd Packages/SoftwareFactoryKit", "  swift test"]),
            .paragraph("Done."),
        ])
    }

    @Test func anUnclosedFenceStillEndsAsCode() {
        #expect(Markdown.blocks("```\nswift test") == [.code(["swift test"])])
    }

    @Test func quotedLinesJoinIntoOneQuote() {
        #expect(Markdown.blocks("> The session\n> is the agent.") == [.quote("The session is the agent.")])
    }

    @Test func inlineMarksAreLeftForTheView() {
        #expect(Markdown.blocks("A **bold** word and `code`.") == [.paragraph("A **bold** word and `code`.")])
        #expect(Markdown.blocks("#NotAHeading") == [.paragraph("#NotAHeading")])
        #expect(Markdown.blocks("-dash") == [.paragraph("-dash")])
        #expect(Markdown.blocks("1.5 of them") == [.paragraph("1.5 of them")])
    }

    @Test func nothingInNothingOut() {
        #expect(Markdown.blocks("") == [])
        #expect(Markdown.blocks("\n\n   \n") == [])
    }
}
