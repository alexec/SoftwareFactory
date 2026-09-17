import Foundation
import Testing
@testable import SoftwareFactoryKit

/// Reading a transcript by the tail rather than from the top, and folding what arrives
/// onto what is already folded. (T503.)
struct TranscriptTailTests {
    private func write(_ text: String, to file: URL) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func chunk(_ words: String, session: String = "s") -> String {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": "session/update", "params": [
            "sessionId": session,
            "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": words]],
        ]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aTailIsOnlyWhatHasArrivedSince() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        try write("one\ntwo\n", to: file)
        let first = store.transcriptTail(for: agent, from: 0)
        #expect(first.lines == ["one", "two"])
        #expect(first.next == 8)
        // Nothing new, so nothing to read and the offset stands.
        let again = store.transcriptTail(for: agent, from: first.next)
        #expect(again.lines.isEmpty)
        #expect(again.next == first.next)
        try append("three\n", to: file)
        let third = store.transcriptTail(for: agent, from: again.next)
        #expect(third.lines == ["three"])
    }

    /// The daemon is appending while this reads, so the end of the file can be half a
    /// line. Taking it would fold a broken line and, worse, move the offset past the whole
    /// of it, so the rest would never be read at all.
    @Test func halfALineIsLeftForNextTime() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        try write("one\ntw", to: file)
        let first = store.transcriptTail(for: agent, from: 0)
        #expect(first.lines == ["one"])
        #expect(first.next == 4)
        try append("o\n", to: file)
        let second = store.transcriptTail(for: agent, from: first.next)
        #expect(second.lines == ["two"])
    }

    @Test func nothingButHalfALineIsNothingRead() throws {
        let store = try temporaryStore()
        let agent = UUID()
        try write("half a li", to: store.transcriptFile(for: agent))
        let tail = store.transcriptTail(for: agent, from: 0)
        #expect(tail.lines.isEmpty)
        #expect(tail.next == 0)
    }

    /// A fresh start deletes the log and begins again, so a file shorter than where the
    /// reader had got to is a different conversation. Folding its lines onto the old one
    /// would show an agent answering the last agent's questions.
    @Test func aLogStartedAgainSaysSoRatherThanBeingFoldedOnTheOldOne() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        try write("one\ntwo\nthree\n", to: file)
        let first = store.transcriptTail(for: agent, from: 0)
        #expect(first.startedAgain == false)
        try write("new\n", to: file)
        let after = store.transcriptTail(for: agent, from: first.next)
        #expect(after.startedAgain)
        #expect(after.lines == ["new"])
        #expect(after.next == 4)
    }

    /// A log that has been taken away, for an agent that was deleted. It reads as started
    /// again rather than as nothing new, or the page would go on showing a conversation
    /// that is not there any more.
    @Test func aLogTakenAwayReadsAsStartedAgain() throws {
        let store = try temporaryStore()
        let agent = UUID()
        #expect(store.transcriptTail(for: agent, from: 0).startedAgain == false)
        #expect(store.transcriptTail(for: agent, from: 40).startedAgain)
    }

    /// The equivalence the whole of T503 rests on: a log read in pieces folds to the same
    /// page as the same log read whole. Chunks joining across the seam are the case that
    /// would break it, so the split is put in the middle of a sentence's chunks.
    @Test func theSameFoldWhetherItIsReadAllAtOnceOrABitAtATime() {
        let lines = [chunk("Reading "), chunk("Models"), chunk(".swift"),
                     chunk(" and then "), chunk("the tests.")]
        let whole = ACPTranscript.folding(lines)
        var bit = ACPTranscript.folding(Array(lines.prefix(2)))
        bit = bit.folding(more: Array(lines.dropFirst(2).prefix(1)))
        bit = bit.folding(more: Array(lines.dropFirst(3)))
        #expect(bit == whole)
        #expect(whole.entries.count == 1)
        #expect(whole.lastSaid == "Reading Models.swift and then the tests.")
    }

    /// And through the store, which is how the app does it: fold, more arrives, fold the
    /// tail onto what is there.
    @Test func aPageFoldedFromTailsIsThePageFoldedFromTheWholeLog() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        try write(chunk("Editing ") + "\n" + chunk("Models.swift") + "\n", to: file)
        let first = store.transcriptTail(for: agent, from: 0)
        var page = ACPTranscript().folding(more: first.lines)
        try append(chunk(", 12 lines") + "\n", to: file)
        let second = store.transcriptTail(for: agent, from: first.next)
        page = page.folding(more: second.lines)
        #expect(page == ACPTranscript.folding(store.transcriptLines(for: agent)))
        #expect(page.lastSaid == "Editing Models.swift, 12 lines")
    }

    // MARK: Opening at the end (T511)

    private func turnEnded(id: Int) -> String {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["stopReason": "end_turn"]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    private func toolCall(_ id: String, title: String) -> String {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": "session/update", "params": [
            "sessionId": "s",
            "update": ["sessionUpdate": "tool_call", "toolCallId": id, "title": title, "status": "pending"],
        ]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    private func toolDone(_ id: String) -> String {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": "session/update", "params": [
            "sessionId": "s",
            "update": ["sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"],
        ]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    /// The claim: a page opened at the end of a log draws the end of the page one folded
    /// from the beginning draws, row for row, and reads a fraction of the log to do it.
    ///
    /// The log here is 200 turns and the window holds a page and a bit of it, which is the
    /// real proportion. What it must not do is differ: same rows, same order, same tool
    /// calls, with the earlier ones left in the log where they belong.
    @Test func aPageOpenedAtTheEndDrawsWhatOneOpenedAtTheStartDraws() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        var lines: [String] = []
        for turn in 1...200 {
            lines.append(toolCall("call-\(turn)", title: "Reading file \(turn)"))
            lines.append(toolDone("call-\(turn)"))
            lines.append(chunk("Turn \(turn) done. "))
            lines.append(turnEnded(id: turn))
        }
        try write(lines.joined(separator: "\n") + "\n", to: file)
        let bytes = try Data(contentsOf: file).count

        let (fromTheEnd, read, _) = ACPTranscript.opening(for: agent, in: store, want: bytes / 8)
        #expect(read == bytes, "the next read must carry on from the end of the file")
        let fromTheStart = ACPTranscript.folding(store.transcriptLines(for: agent))
        // A fraction of the log, and every row of it the same as the end of the full page.
        #expect(fromTheEnd.entries.count < fromTheStart.entries.count / 4)
        let end = fromTheEnd.page(), whole = fromTheStart.page()
        #expect(end.count > 1)
        #expect(end.map(\.entry.kind) == Array(whole.map(\.entry.kind).suffix(end.count)))
        // And it says so, rather than beginning mid-conversation with no explanation.
        #expect(fromTheEnd.openedMidLog)
        #expect(end[0].more)
    }

    /// A short log is read whole, and a page that starts at the top says nothing about
    /// what came before, because nothing did.
    @Test func aShortLogIsOpenedWhole() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        try write([chunk("Only turn. "), turnEnded(id: 1)].joined(separator: "\n") + "\n", to: file)
        let (page, _, _) = ACPTranscript.opening(for: agent, in: store)
        #expect(page.lastSaid == "Only turn. ")
        #expect(!page.openedMidLog)
        #expect(page.page()[0].more == false)
    }

    /// A cut anywhere loses a tool call's name: the opening line carries the title and the
    /// update that follows only merges into it, so a call opened above the cut would draw
    /// as a bare id in the one row somebody is looking at. The cut goes after a turn ended,
    /// where the agent had nothing open.
    @Test func aLogCutInTheMiddleOfAToolCallStillNamesIt() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        let lines = [
            chunk("Old news. "),
            turnEnded(id: 1),
            toolCall("call-2", title: "Editing Models.swift"),
            toolDone("call-2"),
            turnEnded(id: 2),
        ]
        try write(lines.joined(separator: "\n") + "\n", to: file)
        // Small enough that the window opens inside the tool call, between its two lines.
        let opening = store.transcriptOpening(for: agent, want: 120)
        let page = ACPTranscript().folding(more: opening.lines)
        let call = try #require(page.entries.compactMap(\.tool).first)
        #expect(call.title == "Editing Models.swift")
        #expect(call.heading == "Editing Models.swift")
    }

    /// A log with no turn boundary in it at all, which is an agent still on its first turn,
    /// is folded whole. That is what every log did before, and it is the only honest answer:
    /// there is nowhere safe to cut.
    @Test func aLogWithNoTurnEndedYetIsFoldedWhole() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        try write(chunk("Still going") + "\n" + toolCall("c", title: "Reading") + "\n", to: file)
        let opening = store.transcriptOpening(for: agent, want: 8)
        #expect(opening.lines.count == 2)
        #expect(ACPTranscript().folding(more: opening.lines)
            == ACPTranscript.folding(store.transcriptLines(for: agent)))
    }

    // MARK: Scrolling back (T542)

    /// The claim, and the only one worth making: scrolling all the way back gets you the
    /// same conversation as folding the log from the top. Window by window, joined at turn
    /// boundaries, and the result has to be indistinguishable from the thing it is a cheaper
    /// way of reaching.
    @Test func scrollingAllTheWayBackIsTheWholeLog() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        var lines: [String] = []
        for turn in 1...60 {
            lines.append(toolCall("call-\(turn)", title: "Reading file \(turn)"))
            lines.append(toolDone("call-\(turn)"))
            lines.append(chunk("Turn \(turn) done. "))
            lines.append(turnEnded(id: turn))
        }
        try write(lines.joined(separator: "\n") + "\n", to: file)

        // Open at the end with a window far too small to hold it all, then walk backwards.
        let window = 1_500
        var (page, _, start) = ACPTranscript.opening(for: agent, in: store, want: window)
        #expect(page.openedMidLog, "a window this small must have cut the log")
        var reads = 0
        while page.openedMidLog {
            let earlier = ACPTranscript.earlier(for: agent, in: store, before: start, want: window)
            page = page.following(earlier.page)
            start = earlier.from
            reads += 1
            #expect(reads < 200, "it is not getting anywhere")
        }
        #expect(reads > 3, "the window was not small enough to be a real walk")

        let whole = ACPTranscript.folding(store.transcriptLines(for: agent))
        #expect(page.entries.map(\.kind) == whole.entries.map(\.kind))
        #expect(page.entries.map(\.id) == Array(0..<whole.entries.count), "ids are handed out over the whole page")
        #expect(page.page(last: 0).map(\.entry.kind) == whole.page(last: 0).map(\.entry.kind))
        #expect(!page.openedMidLog, "the top of the log is on the page now")
    }

    /// A tool call whose name is in one window and whose update is in the next would come
    /// out as a bare id if the two were joined anywhere but a turn boundary. This is that
    /// case, walked back across the join.
    @Test func aToolCallKeepsItsNameAcrossTheJoin() throws {
        let store = try temporaryStore()
        let agent = UUID()
        let file = store.transcriptFile(for: agent)
        var lines: [String] = []
        for turn in 1...12 {
            lines.append(toolCall("call-\(turn)", title: "Editing Models.swift \(turn)"))
            lines.append(toolDone("call-\(turn)"))
            lines.append(turnEnded(id: turn))
        }
        try write(lines.joined(separator: "\n") + "\n", to: file)

        let window = 900
        var (page, _, start) = ACPTranscript.opening(for: agent, in: store, want: window)
        while page.openedMidLog {
            let earlier = ACPTranscript.earlier(for: agent, in: store, before: start, want: window)
            page = page.following(earlier.page)
            start = earlier.from
        }
        let calls = page.entries.compactMap(\.tool)
        #expect(calls.count == 12)
        for (index, call) in calls.enumerated() {
            #expect(call.title == "Editing Models.swift \(index + 1)")
            #expect(call.status == .completed, "the update found the call it belongs to")
        }
    }

    /// Nothing before the top is not an error, and it is how the page knows to stop asking.
    @Test func thereIsNothingBeforeTheTopOfTheLog() throws {
        let store = try temporaryStore()
        let agent = UUID()
        try write(chunk("Only turn. ") + "\n" + turnEnded(id: 1) + "\n", to: store.transcriptFile(for: agent))
        let nothing = store.transcriptBefore(for: agent, before: 0)
        #expect(nothing.lines.isEmpty)
        #expect(nothing.from == 0)
    }

    /// Nothing there yet is not an error, and the offset stays at nothing so the first real
    /// read starts at the top.
    @Test func openingAnAgentWithNoLogReadsNothing() throws {
        let store = try temporaryStore()
        let opening = store.transcriptOpening(for: UUID())
        #expect(opening.lines.isEmpty)
        #expect(opening.next == 0)
    }
}
