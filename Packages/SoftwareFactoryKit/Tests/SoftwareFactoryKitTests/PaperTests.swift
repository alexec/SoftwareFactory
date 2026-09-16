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

/// Paper is made of seven colours and a measure, and they are written down once. The
/// documents are HTML and the agent's page is SwiftUI, so without one source they would
/// have drifted the first time either was touched. (Alex, 16 Sep 2026.)
struct PaperToneTests {
    @Test func everyToneIsASixDigitColourBothWaysUp() {
        for tone in Paper.Tone.allCases {
            for hex in [tone.hex.light, tone.hex.dark] {
                #expect(hex.count == 6, "\(tone.rawValue): \(hex)")
                #expect(UInt32(hex, radix: 16) != nil, "\(tone.rawValue): \(hex) is not a colour")
            }
        }
    }

    @Test func theStylesheetIsBuiltFromThemRatherThanRepeatingThem() {
        let style = Paper.style
        for tone in Paper.Tone.allCases {
            #expect(style.contains("--\(tone.rawValue): #\(tone.hex.light)"))
            #expect(style.contains("--\(tone.rawValue): #\(tone.hex.dark)"))
        }
    }

    @Test func darkIsItsOwnPaperRatherThanAWhitePageDimmed() {
        // The ground is darker than the ink, the other way up from light.
        let paper = Paper.Tone.paper.hex
        let ink = Paper.Tone.ink.hex
        #expect(UInt32(paper.light, radix: 16)! > UInt32(ink.light, radix: 16)!)
        #expect(UInt32(paper.dark, radix: 16)! < UInt32(ink.dark, radix: 16)!)
    }

    /// Warm, all of it, ground and ink and mark alike. Three other palettes were tried
    /// and this is the one picked with all of them in front of him, so warmth is the
    /// decision rather than an oversight. (Alex, 16 Sep 2026.)
    @Test func thePageIsWarm() {
        for tone in [Paper.Tone.paper, .ink, .quiet, .rule, .edge, .block] {
            for hex in [tone.hex.light, tone.hex.dark] {
                let value = UInt32(hex, radix: 16)!
                let red = (value >> 16) & 0xFF
                let blue = value & 0xFF
                #expect(red > blue, "\(tone.rawValue) #\(hex) is cool, and the page is not")
            }
        }
    }

    @Test func theMarkStandsOutFromTheInkWithoutShouting() {
        // It is the only colour on the page, so what matters is that it is a colour and
        // not a second black.
        for (mark, ink) in [(Paper.Tone.mark.hex.light, Paper.Tone.ink.hex.light),
                            (Paper.Tone.mark.hex.dark, Paper.Tone.ink.hex.dark)] {
            let m = UInt32(mark, radix: 16)!
            let i = UInt32(ink, radix: 16)!
            let spread = { (v: UInt32) in Int((v >> 16) & 0xFF) - Int(v & 0xFF) }
            #expect(abs(spread(m)) > abs(spread(i)), "The mark #\(mark) is no more coloured than the ink")
        }
    }

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

    /// The alarm is louder than the mark, or it is not an alarm. Measured as saturation,
    /// the spread between the reddest and the bluest channel, because that is what makes a
    /// small patch of colour read as a signal rather than as warm paper. (T408.)
    @Test func theAlarmIsLouderThanTheMark() {
        let spread = { (hex: String) -> Int in
            let v = UInt32(hex, radix: 16)!
            return Int((v >> 16) & 0xFF) - Int(v & 0xFF)
        }
        #expect(spread(Paper.Tone.alarm.hex.light) > spread(Paper.Tone.mark.hex.light))
        #expect(spread(Paper.Tone.alarm.hex.dark) > spread(Paper.Tone.mark.hex.dark))
    }
}
