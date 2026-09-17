import Foundation
import Testing
@testable import SoftwareFactoryKit

/// What the factory makes of a sentence. The words are not rewritten: naming the project
/// is taken out of the way and everything else is left exactly as it was said, because
/// every edit is a chance to make a transcription worse. (T340, then T351.)
@Suite struct SpokenTests {
    let sleeper = Project(name: "Sleeper Train")
    let hold = Project(name: "Hold Still")
    let corpo = Project(name: "Corpospeak")
    var all: [Project] { [sleeper, hold, corpo] }

    /// The one that went wrong. Cutting the name out of the middle left "For the" stuck
    /// to the front of the next sentence.
    @Test func aSentenceThatOnlyNamesTheProjectGoesWhole() {
        let heard = Spoken.heard(
            "For the Sleeper Train project. Do not modify the user's dictated text, "
            + "there might be transcription errors. And make the listening area larger.",
            projects: all)
        #expect(heard.projectID == sleeper.id)
        #expect(heard.title == "Do not modify the user's dictated text, there might be transcription errors.")
        #expect(heard.said == "Do not modify the user's dictated text, there might be transcription errors. "
                + "And make the listening area larger.")
    }

    @Test func theProjectAtTheFrontOfOneSentence() {
        let heard = Spoken.heard("on Sleeper Train fix the timetable scrolling", projects: all)
        #expect(heard.projectID == sleeper.id)
        #expect(heard.projectWasSaid)
        #expect(heard.title == "fix the timetable scrolling")
    }

    @Test func theProjectAtTheEnd() {
        let heard = Spoken.heard("fix the timetable scrolling on Sleeper Train", projects: all)
        #expect(heard.projectID == sleeper.id)
        #expect(heard.title == "fix the timetable scrolling")
    }

    /// Said in the middle of a sentence, so it routes the task and the sentence is left
    /// exactly as it was. Cutting it out is what broke T351.
    @Test func aNameInTheMiddleIsLeftWhereItIs() {
        let said = "the Sleeper Train timetable scrolls past the end"
        let heard = Spoken.heard(said, projects: all)
        #expect(heard.projectID == sleeper.id)
        #expect(heard.title == said)
    }

    /// The whole point of doing this with rules. A recogniser mishears a name the way a
    /// typist mistypes one, and Projects.nearMiss already knows that shape of mistake.
    @Test func aMisheardNameStillFindsTheProject() {
        #expect(Spoken.heard("NightSleeper, park the dining car work", projects: all).projectID == sleeper.id)
        #expect(Spoken.heard("on Corpo speak add a settings page", projects: all).projectID == corpo.id)
    }

    @Test func theLongerNameWins() {
        let still = Project(name: "Still")
        let heard = Spoken.heard("Hold Still needs a dark mode", projects: [still, hold])
        #expect(heard.projectID == hold.id)
        #expect(heard.title == "needs a dark mode")
    }

    /// No name said, so the page you are looking at is the project, and nothing at all is
    /// cut. Nothing is guessed when you are looking at nothing.
    @Test func thePageYouAreLookingAt() {
        let said = "the timetable scrolls past the end"
        let onPage = Spoken.heard(said, projects: all, lookingAt: sleeper.id)
        #expect(onPage.projectID == sleeper.id)
        #expect(!onPage.projectWasSaid)
        #expect(onPage.title == said)

        let nowhere = Spoken.heard(said, projects: all)
        #expect(nowhere.projectID == nil)
        #expect(!nowhere.isComplete)
        #expect(nowhere.title == said)
    }

    @Test func aNamedProjectBeatsThePage() {
        #expect(Spoken.heard("on Corpospeak the settings are empty", projects: all,
                             lookingAt: sleeper.id).projectID == corpo.id)
    }

    /// A long dictation is one task: the first sentence names it and the whole of what
    /// was said goes in the note, so a bad split loses nothing.
    @Test func theTitleIsTheFirstSentenceAndTheRestIsKept() {
        let heard = Spoken.heard(
            "Sleeper Train. Fix the timetable. It scrolls past the end and the header sticks.",
            projects: all)
        #expect(heard.title == "Fix the timetable.")
        #expect(heard.said == "Fix the timetable. It scrolls past the end and the header sticks.")
    }

    /// The first word of a title used to name a kind of work, and dictating "design the
    /// seat picker" filed a Design without dictation knowing about work at all. The work is
    /// gone (T417), so the words stay words: what was said is the title and nothing is read
    /// out of its first token.
    @Test func theFirstWordIsJustAWordNow() {
        let design = Spoken.heard("on Sleeper Train design the seat picker", projects: all)
        #expect(design.title == "design the seat picker")
    }

    @Test func nothingSaidIsNothingHeard() {
        let heard = Spoken.heard("   ", projects: all)
        #expect(heard.title.isEmpty)
        #expect(!heard.isComplete)
    }

    @Test func aRemovedProjectIsNotOffered() {
        var gone = Project(name: "Sleeper Train")
        gone.removed = .now
        #expect(Spoken.heard("on Sleeper Train fix it", projects: [gone]).projectID == nil)
    }

    @Test func punctuationIsLeftAlone() {
        let heard = Spoken.heard("Sleeper Train, the timetable is wrong.", projects: all)
        #expect(heard.projectID == sleeper.id)
        #expect(heard.title == "the timetable is wrong.")
    }
}
