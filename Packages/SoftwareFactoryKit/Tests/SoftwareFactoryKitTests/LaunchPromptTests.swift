import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct LaunchPromptTests {
    static let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let project = Project(name: "Walkist")

    @Test func projectPromptNamesTheAgentAndTheProject() {
        let words = LaunchPrompt.project(project, as: "A7", session: Self.session)
        #expect(words.contains("agent \"A7\""))
        #expect(words.contains("project \"Walkist\""))
        #expect(words.contains("Your session_id is \(Self.session.uuidString)"))
        #expect(words.contains("backlog"))
    }

    @Test func taskPromptNamesTheTaskByNumberAndTitle() {
        var task = FactoryTask(projectID: project.id, title: "Move the add row to the bottom", rank: 1)
        task.number = 136
        let words = LaunchPrompt.task(task, in: project, as: "A7", session: Self.session)
        #expect(words.contains("agent \"A7\""))
        #expect(words.contains("project \"Walkist\""))
        #expect(words.contains("T136, \"Move the add row to the bottom\""))
        #expect(words.contains("waiting in your name"))
    }

    @Test func taskPromptWithoutANumberStillNamesTheTask() {
        let task = FactoryTask(projectID: project.id, title: "Move the add row to the bottom", rank: 1)
        let words = LaunchPrompt.task(task, in: project, as: "A7", session: Self.session)
        #expect(words.contains("The task \"Move the add row to the bottom\" is waiting"))
        #expect(words.contains("Do it, and say when it is done."))
        #expect(!words.contains("T,"))
    }

    @Test func taskPromptTellsADesignToStop() {
        let task = FactoryTask(projectID: project.id, title: "The add row", rank: 1, work: .design)
        let words = LaunchPrompt.task(task, in: project, as: "A7", session: Self.session)
        #expect(words.contains("Produce a design brief, put it on the project with artifact_add, then stop. Don't implement."))
        #expect(!words.contains("Do it, and say when it is done."))
    }

    @Test func freePromptCarriesWhatThePersonTyped() {
        let words = LaunchPrompt.free("You're the browser owner.", as: "A7", session: Self.session)
        #expect(words.contains("Your session_id is \(Self.session.uuidString)"))
        #expect(words.hasSuffix("You're the browser owner."))
    }

    /// The person edits the work half; the factory writes the name and the session in
    /// front of it. Launching with the words untouched is the same as launching without
    /// touching them at all. (T260.)
    @Test func theWordsThePersonEditsAreTheDefaultOnes() {
        var task = FactoryTask(projectID: project.id, title: "Move the add row", rank: 1)
        task.number = 136
        #expect(LaunchPrompt.free(LaunchPrompt.projectWork(project), as: "A7", session: Self.session)
                == LaunchPrompt.project(project, as: "A7", session: Self.session))
        #expect(LaunchPrompt.free(LaunchPrompt.taskWork(task, in: project), as: "A7", session: Self.session)
                == LaunchPrompt.task(task, in: project, as: "A7", session: Self.session))
        #expect(!LaunchPrompt.projectWork(project).contains("A7"))
        #expect(!LaunchPrompt.projectWork(project).contains(Self.session.uuidString))
        #expect(LaunchPrompt.taskWork(task, in: project).contains("T136, \"Move the add row\""))
    }

    @Test func aNudgeTellsItToTakeTheNextTask() {
        #expect(LaunchPrompt.nudge.contains("next task"))
        #expect(LaunchPrompt.nudge.contains("backlog"))
    }
}
