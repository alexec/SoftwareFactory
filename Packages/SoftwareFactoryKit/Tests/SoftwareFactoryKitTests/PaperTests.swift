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
        #expect(page.contains("prefers-color-scheme: dark"))
    }
}
