import Foundation
import Testing
@testable import SoftwareFactoryKit

/// The fold, against the same recording. The thing being tested is mostly that 88
/// one-word chunks come out as two sentences: that is the whole difference between a
/// page you can read and a wall of rows. (T373.)
struct ACPTranscriptTests {
    var transcript: ACPTranscript { ACPTranscript.folding(ACPTests.recording) }

    @Test func wordsArriveOneAtATimeAndComeOutAsSentences() throws {
        let said = transcript.entries.compactMap { entry -> String? in
            if case .said(let text) = entry.kind { return text }
            return nil
        }
        // 18 agent_message_chunk updates in the recording, two sentences in the page.
        #expect(said.count == 2)
        #expect(said[0].contains("I’ll read"))
        #expect(said[1] == "Done.")
    }

    @Test func thinkingIsKeptApartFromTalking() {
        let thoughts = transcript.entries.compactMap { entry -> String? in
            if case .thought(let text) = entry.kind { return text }
            return nil
        }
        #expect(thoughts.count == 1)
        #expect(thoughts[0].count > 100)
    }

    @Test func aToolCallAndItsNewsAreOneRow() throws {
        let tools = transcript.entries.compactMap(\.tool)
        // Two tool_call and two tool_call_update in the recording: two rows.
        #expect(tools.count == 2)
        let read = try #require(tools.first)
        #expect(read.kind == .read)
        #expect(read.status == .completed, "The update has to land on the call that started it.")
        #expect(read.title?.contains("hello.txt") == true, "And must not wipe its title.")
    }

    @Test func theLineUnderTheNameIsTheTruthRatherThanAWindowTitle() {
        // Everything finished, so it falls back to the last thing the agent said.
        #expect(transcript.line == "Done.")
        #expect(transcript.isBusy == false)
    }

    @Test func aRunningToolWinsTheLine() {
        var live = ACPTranscript()
        live.apply(.message(.text("I will start now.")))
        live.apply(.tool(ACP.ToolCall(toolCallID: "c1", title: "Editing Models.swift",
                                      kind: .edit, status: .inProgress)))
        #expect(live.line == "Editing Models.swift")
        #expect(live.isBusy)
        live.apply(.tool(ACP.ToolCall(toolCallID: "c1", status: .completed)))
        #expect(live.line == "I will start now.")
        #expect(live.isBusy == false)
    }

    @Test func aCallWithNoTitleStillSaysSomething() {
        var live = ACPTranscript()
        live.apply(.tool(ACP.ToolCall(toolCallID: "c1", kind: .execute, status: .inProgress)))
        #expect(live.line == "Running")
    }

    @Test func whatItHasActuallyChanged() {
        #expect(transcript.filesTouched.map { ($0 as NSString).lastPathComponent } == ["note.md"])
    }

    @Test func howFullItsHeadIs() throws {
        let used = try #require(transcript.contextUsed)
        #expect(used > 0 && used < 1)
        #expect(transcript.size == 272_000)
    }

    @Test func foldingTheSameLogTwiceGivesTheSamePage() {
        #expect(ACPTranscript.folding(ACPTests.recording) == ACPTranscript.folding(ACPTests.recording))
    }

    @Test func whatWeSaidIsWrittenDownBecauseTheAgentDoesNotEchoIt() {
        var live = ACPTranscript()
        live.weSaid("  The user has nudged you to continue your work.  ")
        live.apply(.message(.text("Right.")))
        #expect(live.entries.count == 2)
        #expect(live.entries[0].text == "The user has nudged you to continue your work.")
        live.weSaid("   ")
        #expect(live.entries.count == 2, "Nothing said is nothing written down.")
    }

    @Test func aPlanIsReplacedRatherThanRepeated() {
        var live = ACPTranscript()
        live.apply(.plan([ACP.PlanEntry(title: "Read it", status: "in_progress")]))
        live.apply(.plan([ACP.PlanEntry(title: "Read it", status: "completed"),
                          ACP.PlanEntry(title: "Write it", status: "pending")]))
        #expect(live.plan.count == 2)
        #expect(live.plan[0].isDone)
        #expect(live.entries.isEmpty, "A plan is not an entry: it is rewritten, not added to.")
    }

    @Test func anEmptyChunkAddsNothing() {
        var live = ACPTranscript()
        live.apply(.message(.text("")))
        #expect(live.entries.isEmpty)
    }

    @Test func aTranscriptOfNothingSaysNothingRatherThanBreaking() {
        let empty = ACPTranscript()
        #expect(empty.line == nil)
        #expect(empty.lastSaid == nil)
        #expect(empty.contextUsed == nil)
        #expect(empty.filesTouched.isEmpty)
        #expect(empty.isBusy == false)
    }

    @Test func lineStaysShortEnoughForACard() {
        var live = ACPTranscript()
        live.apply(.message(.text(String(repeating: "x", count: 500) + "\nsecond line")))
        #expect(live.line?.count == Agent.maxTitle)
    }

    @Test func imagesAndAttachmentsAreNamedRatherThanBlank() {
        var live = ACPTranscript()
        live.apply(.message(.image))
        #expect(live.entries.first?.text == "[image]")
    }
}

/// The same fold against a second agent, `claude-agent-acp`, recorded the same way. Two
/// agents rather than one because they do not send the same shapes: a tool call's
/// `content` is a list and a message chunk's is an object, and a client that quietly
/// assumed one of them would lose half a conversation. (T373.)
struct ACPClaudeTranscriptTests {
    static let recording: [String] = {
        guard let url = Bundle.module.url(forResource: "claude-session", withExtension: "jsonl",
                                          subdirectory: "Fixtures"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map(String.init)
    }()

    var transcript: ACPTranscript { ACPTranscript.folding(Self.recording) }

    @Test func everyLineIsPlaced() {
        let lost = Self.recording.filter {
            if case .unrecognised = ACP.read(line: $0) { return true }
            return false
        }
        #expect(lost.isEmpty, "Unplaced: \(lost.prefix(1))")
    }

    @Test func itReadsAsAConversationWithBothSidesInIt() throws {
        let page = transcript
        // What we said, what it did, what it said, twice over.
        let shape = page.entries.map { entry -> String in
            switch entry.kind {
            case .asked: "asked"
            case .said: "said"
            case .thought: "thought"
            case .tool: "tool"
            }
        }
        #expect(shape == ["asked", "tool", "said", "asked", "said"])
    }

    @Test func theWordsTheFactorySaidAreInTheLog() throws {
        let asked = transcript.entries.compactMap { entry -> String? in
            if case .asked(let text) = entry.kind { return text }
            return nil
        }
        #expect(asked.count == 2)
        #expect(asked[0].hasPrefix("Read README.md"))
        #expect(asked[1] == "Now reply with just the word ACKNOWLEDGED.")
    }

    @Test func aToolCallsContentIsAListAndAChunksIsNot() throws {
        let tool = try #require(transcript.entries.compactMap(\.tool).first)
        #expect(tool.kind == .read)
        #expect(tool.status == .completed)
        #expect(tool.title == "Read README.md", "The update renames the call, and that has to land.")
    }

    @Test func chunksSplitAcrossAWordStillMakeTheWord() {
        // "ACKNOWLE" and "DGED" arrived as two chunks.
        #expect(transcript.lastSaid == "ACKNOWLEDGED")
        #expect(transcript.line == "ACKNOWLEDGED")
    }
}

/// The bounded version of the same question, which is what the daemon keeps.
struct ACPHeadlineTests {
    @Test func itSaysTheSameThingAsTheWholeTranscript() {
        var headline = ACPHeadline()
        for line in ACPTests.recording { headline.apply(line: line) }
        #expect(headline.line == ACPTranscript.folding(ACPTests.recording).line)
        #expect(headline.isBusy == false)
    }

    @Test func andForTheOtherAgentToo() {
        var headline = ACPHeadline()
        for line in ACPClaudeTranscriptTests.recording { headline.apply(line: line) }
        #expect(headline.line == "ACKNOWLEDGED")
    }

    @Test func aRunningToolWins() {
        var headline = ACPHeadline()
        headline.apply(.message(.text("Starting.")))
        headline.apply(.tool(ACP.ToolCall(toolCallID: "a", title: "Editing Models.swift",
                                          kind: .edit, status: .inProgress)))
        #expect(headline.line == "Editing Models.swift")
        #expect(headline.isBusy)
        // Two at once: the newest is what it is doing.
        headline.apply(.tool(ACP.ToolCall(toolCallID: "b", title: "Running tests",
                                          kind: .execute, status: .inProgress)))
        #expect(headline.line == "Running tests")
        headline.apply(.tool(ACP.ToolCall(toolCallID: "b", status: .completed)))
        #expect(headline.line == "Editing Models.swift")
        headline.apply(.tool(ACP.ToolCall(toolCallID: "a", status: .completed)))
        #expect(headline.isBusy == false)
        #expect(headline.line == "Starting.")
    }

    @Test func itNeverGrows() {
        var headline = ACPHeadline()
        for turn in 0..<2000 {
            headline.apply(.message(.text("word \(turn) ")))
            headline.apply(.tool(ACP.ToolCall(toolCallID: "t\(turn)", title: "Reading", kind: .read,
                                              status: .pending)))
            headline.apply(.tool(ACP.ToolCall(toolCallID: "t\(turn)", status: .completed)))
        }
        // One sentence and no open calls: nothing here is a list of everything that has
        // happened. The last thing it said wins over the last thing it did, which is why
        // this is the word and not "Reading".
        #expect(headline.isBusy == false)
        #expect(headline.line == "word 1999")
    }

    @Test func aNewTurnStartsANewSentence() {
        var headline = ACPHeadline()
        headline.apply(.message(.text("First answer.")))
        headline.apply(.userMessage(.text("Do something else.")))
        headline.apply(.message(.text("Second answer.")))
        #expect(headline.line == "Second answer.")
    }
}

/// Runs of tool calls, collapsed. An agent reads four files and searches twice before it
/// writes anything, and a dozen finished rows bury the two things worth reading.
struct ACPTranscriptPageTests {
    private func tool(_ id: String, _ title: String, done: Bool = true) -> ACP.Update {
        .tool(ACP.ToolCall(toolCallID: id, title: title, kind: .read,
                           status: done ? .completed : .inProgress))
    }

    @Test func aRunOfThemShowsItsMostRecent() {
        var page = ACPTranscript()
        page.weSaid("get on with it")
        for n in 1...5 { page.apply(tool("t\(n)", "Reading file\(n).swift")) }
        page.apply(.message(.text("Done.")))

        let rows = page.page()
        #expect(rows.count == 3, "Asked, one tool row, said.")
        #expect(rows[1].entry.tool?.title == "Reading file5.swift")
        #expect(rows[1].before == 4)
        #expect(rows[1].alsoRan == "4 steps before this")
    }

    @Test func aRunStartsAgainAfterTheAgentSaysSomething() {
        var page = ACPTranscript()
        page.apply(tool("a", "Reading one"))
        page.apply(tool("b", "Reading two"))
        page.apply(.message(.text("Now I will write it.")))
        page.apply(tool("c", "Editing three"))
        page.apply(tool("d", "Editing four"))

        let rows = page.page()
        #expect(rows.map(\.before) == [1, 0, 1])
        #expect(rows[0].entry.tool?.title == "Reading two")
        #expect(rows[2].entry.tool?.title == "Editing four")
    }

    @Test func theOneStillRunningIsTheOneYouSee() {
        var page = ACPTranscript()
        page.apply(tool("a", "Reading one"))
        page.apply(tool("b", "Running the tests", done: false))
        let rows = page.page()
        #expect(rows.count == 1)
        #expect(rows[0].entry.tool?.title == "Running the tests")
        #expect(rows[0].entry.tool?.isFinished == false)
    }

    @Test func aThoughtBetweenTwoToolsDoesNotSplitTheRun() {
        var page = ACPTranscript()
        page.apply(tool("a", "Reading one"))
        page.apply(.thought(.text("Hmm.")))
        page.apply(tool("b", "Reading two"))
        // Thinking hidden, which is the default: one run of two.
        #expect(page.page().count == 1)
        #expect(page.page()[0].before == 1)
        // Thinking shown: the thought is a row, so it is two runs of one.
        let withThinking = page.page(thinking: true)
        #expect(withThinking.count == 3)
        #expect(withThinking.map(\.before) == [0, 0, 0])
    }

    @Test func oneOnItsOwnSaysNothingAboutStepsBefore() {
        var page = ACPTranscript()
        page.apply(tool("a", "Reading one"))
        #expect(page.page()[0].before == 0)
        #expect(page.page()[0].alsoRan == nil)
    }

    @Test func oneStepBeforeIsSingular() {
        var page = ACPTranscript()
        page.apply(tool("a", "Reading one"))
        page.apply(tool("b", "Reading two"))
        #expect(page.page()[0].alsoRan == "1 step before this")
    }

    @Test func aPageOfNothingIsNoRows() {
        #expect(ACPTranscript().page().isEmpty)
    }

    @Test func therealRecordingCollapses() {
        let whole = ACPTranscript.folding(ACPClaudeTranscriptTests.recording)
        // asked, tool, said, asked, said. Nothing to collapse there, and it must not
        // lose anything either.
        #expect(whole.page().count == whole.entries.filter {
            if case .thought = $0.kind { return false }
            return true
        }.count)
    }
}

/// A conversation is long and what anybody reads is the end of it. (T467.)
@Suite struct PageLengthTests {
    private func transcript(saying many: Int) -> ACPTranscript {
        var t = ACPTranscript()
        for i in 1...many { t.apply(.message(.text("line \(i)"))) ; t.apply(.userMessage(.text("ask \(i)")) ) }
        return t
    }

    @Test func onlyTheEndIsDrawnAndThePageSaysSo() {
        let t = transcript(saying: 80)
        let all = t.page(last: 0)
        let page = t.page()
        #expect(all.count > ACPTranscript.pageLength)
        #expect(page.count == ACPTranscript.pageLength)
        #expect(page.first?.earlier == all.count - ACPTranscript.pageLength)
        // The end of the page is the end of the conversation, which is what you came for.
        #expect(page.last?.id == all.last?.id)
    }

    @Test func aShortConversationSaysNothingAboutEarlierRows() {
        let page = transcript(saying: 3).page()
        #expect(page.count == 6)
        #expect(page.allSatisfy { $0.earlier == 0 })
    }
}
