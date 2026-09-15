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
