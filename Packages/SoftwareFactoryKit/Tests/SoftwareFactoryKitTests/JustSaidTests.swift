import Foundation
import Testing
@testable import SoftwareFactoryKit

/// What you have just said, held until the daemon's own record shows it. (T495.)
struct JustSaidTests {
    private func asked(_ words: [String]) -> [ACPTranscript.Entry] {
        words.enumerated().map { ACPTranscript.Entry(id: $0.offset, kind: .asked($0.element)) }
    }

    @Test func wordsAreHeldUntilTheyComeBackOffTheLog() {
        var mine = JustSaid()
        mine.add("look at Models.swift", alreadySaid: 0)
        #expect(mine.waiting.count == 1)
        // The daemon has not written it yet.
        mine.settle { JustSaid.timesSaid($0, in: asked([]), queued: []) }
        #expect(mine.waiting.count == 1)
        // And now it has.
        mine.settle { JustSaid.timesSaid($0, in: asked(["look at Models.swift"]), queued: []) }
        #expect(mine.isEmpty)
    }

    /// The queue is the other place a send lands: an agent mid-turn is told nothing, so the
    /// daemon holds the words and the page draws them as a Queued bubble. One line either
    /// way, never the echo and the bubble together.
    @Test func wordsQueuedForABusyAgentSettleTheEchoToo() {
        var mine = JustSaid()
        mine.add("and then run the tests", alreadySaid: 0)
        mine.settle { JustSaid.timesSaid($0, in: asked([]), queued: ["and then run the tests"]) }
        #expect(mine.isEmpty)
    }

    /// The same words twice is the ordinary case, because the field's default is one word
    /// and pressing return twice is how you say it twice. Matching on the words alone would
    /// drop both echoes when the first landed, and the second would vanish for a second and
    /// come back.
    @Test func theSameWordsTwiceLandOneAtATime() {
        var mine = JustSaid()
        let count: ([String], [String]) -> (String) -> Int = { entries, queued in
            { JustSaid.timesSaid($0, in: self.asked(entries), queued: queued) }
        }
        mine.add("continue", alreadySaid: JustSaid.timesSaid("continue", in: asked([]), queued: []))
        mine.add("continue", alreadySaid: JustSaid.timesSaid("continue", in: asked([]), queued: []))
        #expect(mine.waiting.map(\.alreadySaid) == [0, 1])
        mine.settle(count(["continue"], []))
        #expect(mine.waiting.count == 1)
        mine.settle(count(["continue"], ["continue"]))
        #expect(mine.isEmpty)
    }

    /// Words said in an earlier turn are not this send arriving. An agent asked to continue
    /// nine times today has nine of them in its log, and the tenth is the one being waited
    /// on.
    @Test func anOlderCopyOfTheSameWordsIsNotThisOneLanding() {
        var mine = JustSaid()
        let already = JustSaid.timesSaid("continue", in: asked(["continue", "continue"]), queued: [])
        #expect(already == 2)
        mine.add("continue", alreadySaid: already)
        mine.settle { JustSaid.timesSaid($0, in: self.asked(["continue", "continue"]), queued: []) }
        #expect(mine.waiting.count == 1)
        mine.settle { JustSaid.timesSaid($0, in: self.asked(["continue", "continue", "continue"]), queued: []) }
        #expect(mine.isEmpty)
    }

    /// A send can fail: the agent has stopped, or the daemon has nobody by that name. An
    /// optimistic line that quietly stays looks exactly like one that landed, so it says so
    /// and stays until the person takes it back.
    @Test func oneThatDidNotGoSaysSoAndIsNeverSettledAway() {
        var mine = JustSaid()
        let id = mine.add("carry on", alreadySaid: 0)
        mine.failed(id, why: "It is not running.")
        #expect(mine.waiting.first?.didNotGo == true)
        mine.settle { JustSaid.timesSaid($0, in: self.asked(["carry on"]), queued: []) }
        #expect(mine.waiting.count == 1)
        mine.drop(id)
        #expect(mine.isEmpty)
    }

    /// One that failed stops being something the next echo is waiting on. Two of the same
    /// words, the first refused: the second is now the first arrival rather than the second,
    /// and counting the failed one would leave it on the page for ever.
    @Test func aFailureDoesNotLeaveTheNextOneWaitingForever() {
        var mine = JustSaid()
        let first = mine.add("continue", alreadySaid: 0)
        mine.add("continue", alreadySaid: 0)
        #expect(mine.waiting.map(\.alreadySaid) == [0, 1])
        mine.failed(first, why: "It is not running.")
        #expect(mine.waiting.map(\.alreadySaid) == [0, 0])
        mine.settle { JustSaid.timesSaid($0, in: self.asked(["continue"]), queued: []) }
        #expect(mine.waiting.count == 1)
        #expect(mine.waiting.first?.id == first)
    }

    /// Somebody else's words in the log are not yours. Only `asked` entries count, and the
    /// agent saying the same sentence back is the agent talking.
    @Test func onlyWhatWasSaidToItCounts() {
        let entries = [ACPTranscript.Entry(id: 0, kind: .said("continue")),
                       ACPTranscript.Entry(id: 1, kind: .thought("continue")),
                       ACPTranscript.Entry(id: 2, kind: .asked("continue"))]
        #expect(JustSaid.timesSaid("continue", in: entries, queued: []) == 1)
    }
}
