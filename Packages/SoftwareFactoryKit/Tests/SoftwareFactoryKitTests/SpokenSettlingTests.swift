import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct SpokenSettlingTests {
    private let sleeper = Project(name: "Sleeper Train")
    private let factory = Project(name: "Software Factory")

    private var projects: [Project] { [sleeper, factory] }

    @Test func aPauseThatNamesNoProjectChangesNothing() {
        let settled = Spoken.settling("fix the timetable", projects: projects, project: sleeper.id)
        #expect(settled.projectID == sleeper.id)
        #expect(settled.projectWasSaid == false)
        #expect(settled.words == "fix the timetable")
    }

    @Test func namingAProjectWinsOverTheOneAlreadyOnTheRow() {
        let settled = Spoken.settling("on Sleeper Train, fix the timetable",
                                      projects: projects, project: factory.id)
        #expect(settled.projectID == sleeper.id)
        #expect(settled.projectWasSaid)
        #expect(settled.words == "fix the timetable")
    }

    @Test func aMisheardNameStillFindsIt() {
        let settled = Spoken.settling("NightSleeper. Fix the timetable.",
                                      projects: projects, project: nil)
        #expect(settled.projectID == sleeper.id)
        #expect(settled.words == "Fix the timetable.")
    }

    @Test func aNameInTheMiddleRoutesItAndLeavesTheWordsAlone() {
        let said = "the Sleeper Train timetable is wrong"
        let settled = Spoken.settling(said, projects: projects, project: nil)
        #expect(settled.projectID == sleeper.id)
        #expect(settled.words == said)
    }

    @Test func aRemovedProjectIsNotAPlaceToPutWork() {
        var gone = Project(name: "Sleeper Train")
        gone.removed = .now
        let settled = Spoken.settling("on Sleeper Train, fix it", projects: [gone], project: nil)
        #expect(settled.projectID == nil)
        #expect(settled.words == "on Sleeper Train, fix it")
    }

    @Test func wordsLandInTheTaskAsTheyAreRecognised() {
        #expect(Spoken.appended("", "Fix the timetable") == "Fix the timetable")
        #expect(Spoken.appended("Fix the timetable.", "It runs past the end.")
                == "Fix the timetable. It runs past the end.")
        #expect(Spoken.appended("Fix the timetable.", "   ") == "Fix the timetable.")
        #expect(Spoken.appended("", "  ").isEmpty)
    }

    @Test func nothingSomebodySaidIsRewritten() {
        // No capital put on the front, no stop put on the end, and a space the person
        // left is theirs.
        #expect(Spoken.appended("half a thought", "and the rest") == "half a thought and the rest")
        #expect(Spoken.appended("a line\n", "the next") == "a line\nthe next")
    }

    @Test func aDictatedThoughtIsATitleAndTheWholeOfItUnderneath() {
        let filed = Spoken.filing("Fix the timetable. It runs past the end of the page.")
        #expect(filed.title == "Fix the timetable.")
        #expect(filed.note == "Said: Fix the timetable. It runs past the end of the page.")
    }

    @Test func oneSentenceNeedsNoNote() {
        let filed = Spoken.filing("  Fix the timetable  ")
        #expect(filed.title == "Fix the timetable")
        #expect(filed.note.isEmpty)
    }

    @Test func aLineBreakSaysWhereTheTitleEnds() {
        let filed = Spoken.filing("Fix the timetable\nIt runs past the end. And the top.")
        #expect(filed.title == "Fix the timetable")
        #expect(filed.note == "It runs past the end. And the top.")
    }

    @Test func nothingSaidFilesNothing() {
        #expect(Spoken.filing("   \n ").title.isEmpty)
    }
}

/// Dictation lands in the field itself, and the tail still being revised is replaced
/// rather than repeated. (T372.)
@Suite struct SpokenLiveTests {
    @Test func theTailIsReplacedAndWhatSettledStays() {
        var state = Spoken.live(words: "Fix the timetable", tail: "", volatile: "on the")
        #expect(state.words == "Fix the timetable on the")
        #expect(state.tail == " on the")

        // The recogniser thinks again about the same few words.
        state = Spoken.live(words: state.words, tail: state.tail, volatile: "on the sleeper")
        #expect(state.words == "Fix the timetable on the sleeper")
        #expect(state.tail == " on the sleeper")
    }

    @Test func settlingLeavesNothingBehind() {
        let live = Spoken.live(words: "Fix the timetable", tail: "", volatile: "on the sleeper")
        // What settles goes in behind the tail, so the tail comes out first.
        let bare = Spoken.live(words: live.words, tail: live.tail, volatile: "")
        #expect(bare.words == "Fix the timetable")
        #expect(bare.tail.isEmpty)
        #expect(Spoken.appended(bare.words, "on the sleeper train") == "Fix the timetable on the sleeper train")
    }

    @Test func aCorrectionInFrontOfTheTailSurvivesIt() {
        let live = Spoken.live(words: "Fix the timetable", tail: "", volatile: "on the")
        // The person edits what has already settled while the tail is still moving.
        let edited = live.words.replacingOccurrences(of: "Fix", with: "Code")
        let next = Spoken.live(words: edited, tail: live.tail, volatile: "on the sleeper")
        #expect(next.words == "Code the timetable on the sleeper")
    }

    @Test func anEmptyFieldTakesTheTailWithNoSpaceInFront() {
        let live = Spoken.live(words: "", tail: "", volatile: "  fix the timetable ")
        #expect(live.words == "fix the timetable")
        #expect(live.tail == "fix the timetable")
    }
}
