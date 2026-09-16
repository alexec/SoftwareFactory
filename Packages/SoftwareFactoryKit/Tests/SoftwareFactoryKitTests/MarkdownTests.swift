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

@Suite struct MarkdownSummaryTests {
    @Test func aHeadingAndItsParagraphReadAsOneLine() {
        let text = """
        # The plan

        Take the **bell** out of the live path and put it in a `hook`.
        """
        #expect(Markdown.summary(text) == "The plan Take the bell out of the live path and put it in a hook.")
    }

    @Test func codeAndRulesAreNotSaidOnACard() {
        let text = """
        ---
        ```
        swift test
        ```
        What it does.
        """
        #expect(Markdown.summary(text) == "What it does.")
    }

    @Test func aLinkKeepsItsWordsAndLosesItsAddress() {
        #expect(Markdown.summary("See [the report](https://example.com/r) for the rest.")
                == "See the report for the rest.")
    }

    @Test func nothingIsCutMidWord() {
        let long = String(repeating: "alpha beta ", count: 40)
        let short = Markdown.summary(long, limit: 20)
        #expect(short.count <= 21)
        #expect(short.hasSuffix("…"))
        #expect(!short.contains("alph…"))
    }

    @Test func anEmptyDocumentSaysNothing() {
        #expect(Markdown.summary("").isEmpty)
        #expect(Markdown.summary("```\nonly code\n```").isEmpty)
    }
}

/// A long bullet is wrapped by indenting what follows it. Without this the item came
/// apart on the page: half the sentence in the bullet, the rest underneath as its own
/// paragraph. (T311.)
@Suite struct MarkdownWrappedItemTests {
    @Test func anIndentedLineIsTheRestOfTheBulletAboveIt() {
        let blocks = Markdown.blocks("""
        - **Needs you.** An agent raises a question with two
          or more options and marks the one it recommends.
        - **Artifacts.** Documents on a project.
        """)
        #expect(blocks == [
            .bullet(text: "**Needs you.** An agent raises a question with two or more options and marks the one it recommends.", indent: 0),
            .bullet(text: "**Artifacts.** Documents on a project.", indent: 0),
        ])
    }

    @Test func aNumberedItemWrapsTheSameWay() {
        let blocks = Markdown.blocks("""
        1. Quit the running app
           with software-factory quit.
        """)
        #expect(blocks == [.numbered(number: 1, text: "Quit the running app with software-factory quit.")])
    }

    /// A blank line ends the item. What comes after it is a paragraph, wherever it sits.
    @Test func aBlankLineEndsTheItem() {
        let blocks = Markdown.blocks("""
        - One

          Something else entirely.
        """)
        #expect(blocks == [.bullet(text: "One", indent: 0), .paragraph("Something else entirely.")])
    }

    /// An indented line that is itself a bullet is still a list inside a list.
    @Test func anIndentedBulletIsStillABullet() {
        let blocks = Markdown.blocks("""
        - Agents
          - Embedded
        """)
        #expect(blocks == [
            .bullet(text: "Agents", indent: 0),
            .bullet(text: "Embedded", indent: 1),
        ])
    }

    /// A table is a table, so a palette or a scale in a brief reads as a grid rather than
    /// as a run of pipes. (T391.)
    @Test func aPipeTableIsATable() {
        let blocks = Markdown.blocks("""
        | Tone | Light | For |
        | --- | :---: | --- |
        | `paper` | fbfaf6 | the ground |
        | `ink` | 22201c | what is written |
        """)
        #expect(blocks == [.table(head: ["Tone", "Light", "For"], rows: [
            ["`paper`", "fbfaf6", "the ground"],
            ["`ink`", "22201c", "what is written"],
        ])])
    }

    /// Without the dashes it is not a table. A line quoting a shell pipe would otherwise
    /// come out as a one-cell grid with a border around it.
    @Test func aPipeLineOnItsOwnIsProse() {
        let blocks = Markdown.blocks("| head -1 is not a table")
        #expect(blocks == [.paragraph("| head -1 is not a table")])
    }

    /// A row short of a cell is made up to the heading's width, so what is there still
    /// lines up with the column above it.
    @Test func aShortRowIsMadeUpToTheHeading() {
        let blocks = Markdown.blocks("""
        | One | Two | Three |
        | --- | --- | --- |
        | a | b |
        """)
        #expect(blocks == [.table(head: ["One", "Two", "Three"], rows: [["a", "b", ""]])])
    }

    /// What is written round a table keeps its place either side of it.
    @Test func aTableSitsBetweenWhatWasWrittenAroundIt() {
        let blocks = Markdown.blocks("""
        The scale:

        | Name | Points |
        | --- | --- |
        | card | 18 |

        Everything else names one of these.
        """)
        #expect(blocks == [
            .paragraph("The scale:"),
            .table(head: ["Name", "Points"], rows: [["card", "18"]]),
            .paragraph("Everything else names one of these."),
        ])
    }

    /// A card shows what a document says, and a grid squeezed into one line says how it
    /// was laid out instead.
    @Test func aSummarySkipsTheTable() {
        let text = """
        The house palette.

        | Tone | Light |
        | --- | --- |
        | paper | fbfaf6 |
        """
        #expect(Markdown.summary(text) == "The house palette.")
    }
}
