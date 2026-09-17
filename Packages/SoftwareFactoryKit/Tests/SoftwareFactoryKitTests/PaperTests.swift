import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct PaperTests {
    @Test func headingsParagraphsAndRules() {
        let html = Paper.html("""
        # The iPad app

        The floor on a big screen
        you can pick up.

        ---
        """)
        #expect(html == """
        <h1>The iPad app</h1>
        <p>The floor on a big screen you can pick up.</p>
        <hr>
        """)
    }

    @Test func bulletsBecomeOneList() {
        let html = Paper.html("""
        - One
        - Two
        - Three
        """)
        #expect(html == "<ul><li>One</li><li>Two</li><li>Three</li></ul>")
    }

    @Test func anIndentedBulletIsAListInsideTheItemAboveIt() {
        let html = Paper.html("""
        - Agents
          - Embedded
          - External
        - Projects
        """)
        #expect(html == "<ul><li>Agents<ul><li>Embedded</li><li>External</li></ul></li><li>Projects</li></ul>")
    }

    @Test func numbersKeepTheirOwnStart() {
        let html = Paper.html("""
        3. Third
        4. Fourth
        """)
        #expect(html == "<ol start=\"3\"><li>Third</li><li>Fourth</li></ol>")
    }

    @Test func codeFencesKeepTheirLinesAndTheirAngleBrackets() {
        let html = Paper.html("""
        ```
        if a < b { go() }
        ```
        """)
        #expect(html == "<pre><code>if a &lt; b { go() }</code></pre>")
    }

    @Test func quotesAreQuoted() {
        #expect(Paper.html("> Said once") == "<blockquote><p>Said once</p></blockquote>")
    }

    @Test func boldItalicAndCodeInsideALine() {
        #expect(Paper.inline("**Stop** just *stops*, see `agent_nudge`")
                == "<strong>Stop</strong> just <em>stops</em>, see <code>agent_nudge</code>")
    }

    @Test func aMarkWithSpaceAroundItIsJustAnAsterisk() {
        #expect(Paper.inline("2 * 3 * 4") == "2 * 3 * 4")
    }

    @Test func anUnderscoreInsideAWordIsPartOfTheWord() {
        #expect(Paper.inline("call task_next then task_claim") == "call task_next then task_claim")
    }

    @Test func linksKeepTheirWordsAndTheirAddress() {
        #expect(Paper.inline("[the plan](https://example.com/plan)")
                == "<a href=\"https://example.com/plan\">the plan</a>")
    }

    /// A document is written by an agent, and the app shows it in a web view. A link
    /// that runs script is not a link.
    @Test func javascriptIsNotALink() {
        #expect(Paper.safeHref("javascript:alert(1)") == nil)
        #expect(Paper.inline("[go](javascript:alert(1))") == "[go](javascript:alert(1))")
        #expect(Paper.safeHref("notes/plan.md") == "notes/plan.md")
        #expect(Paper.safeHref("#later") == "#later")
    }

    @Test func markupInTheTextIsShownRatherThanDrawn() {
        #expect(Paper.html("Use <script>alert(1)</script> nowhere")
                == "<p>Use &lt;script&gt;alert(1)&lt;/script&gt; nowhere</p>")
    }

    @Test func aPageCarriesItsTitleAndItsStyle() {
        let page = Paper.page(markdown: "# Hello", title: "A plan & a half")
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("<title>A plan &amp; a half</title>"))
        #expect(page.contains("<h1>Hello</h1>"))
        #expect(page.contains("color-scheme: light dark"))
    }
}

/// A document is set in the system's own colours and the system's own type, and the whole
/// point of that is that it names nothing of its own. These guard the absence: a hex
/// colour or a serif creeping back in is the house theme returning one line at a time,
/// which is how it arrived the first time.
/// (Alex, 16 Sep 2026: conventional Liquid Glass, documents included.)
struct PaperToneTests {
    @Test func theGroundAndTheInkAreTheSystemsOwn() {
        let style = Paper.style
        #expect(style.contains("color-scheme: light dark"))
        #expect(style.contains("background: Canvas"))
        #expect(style.contains("color: CanvasText"))
        // No second palette for dark. `color-scheme` and the system colours follow the
        // appearance on their own, so a dark override is a chance for the two to disagree.
        #expect(!style.contains("prefers-color-scheme"))
    }

    @Test func nothingOnThePageNamesAColourOfItsOwn() {
        // Everything quieter than the body is mixed out of the ink rather than named, so
        // there is one rule both ways up instead of two palettes that can drift.
        for line in Paper.style.split(separator: "\n") {
            #expect(!line.contains("#"), "A colour of our own is back: \(line)")
        }
    }

    @Test func theLettersAreTheSystemsAndNotASerif() {
        #expect(Paper.style.contains("-apple-system"))
        #expect(!Paper.style.contains("serif") || Paper.style.contains("sans-serif"))
        #expect(!Paper.style.contains("ui-serif"))
        #expect(!Paper.style.contains("Georgia"))
    }

    /// The one thing kept when the theme went. A measurement rather than a look: a
    /// sentence running the width of a wide window is hard to read whatever it is set in.
    @Test func thereIsAMeasureAndItIsTheOneTheDocumentsUse() {
        #expect(Paper.measure == 690)
        #expect(Paper.style.contains("max-width: 46em"))
    }

    /// A table comes out as a table, with what is inside a cell read the way a line is
    /// read anywhere else. (T391.)
    @Test func aTableIsSetAsATable() {
        let html = Paper.html("""
        | Tone | For |
        | --- | --- |
        | `paper` | the **ground** |
        """)
        #expect(html.contains("<table><thead><tr><th>Tone</th><th>For</th></tr></thead>"))
        #expect(html.contains("<td><code>paper</code></td><td>the <strong>ground</strong></td>"))
    }

}
