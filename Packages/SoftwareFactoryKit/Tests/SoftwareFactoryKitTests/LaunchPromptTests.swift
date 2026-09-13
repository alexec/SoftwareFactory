import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct LaunchPromptTests {
    let project = Project(name: "Walkist")

    @Test func projectPromptNamesTheAgentAndTheProject() {
        let words = LaunchPrompt.project(project, as: "A7")
        #expect(words.contains("agent \"A7\""))
        #expect(words.contains("project \"Walkist\""))
        #expect(words.contains("agent_id \"A7\""))
        #expect(words.contains("backlog"))
    }

    @Test func taskPromptNamesTheTaskByNumberAndTitle() {
        var task = FactoryTask(projectID: project.id, title: "Move the add row to the bottom", rank: 1)
        task.number = 136
        let words = LaunchPrompt.task(task, in: project, as: "A7")
        #expect(words.contains("agent \"A7\""))
        #expect(words.contains("project \"Walkist\""))
        #expect(words.contains("T136, \"Move the add row to the bottom\""))
        #expect(words.contains("waiting in your name"))
    }

    @Test func taskPromptWithoutANumberStillNamesTheTask() {
        let task = FactoryTask(projectID: project.id, title: "Move the add row to the bottom", rank: 1)
        let words = LaunchPrompt.task(task, in: project, as: "A7")
        #expect(words.contains("The task \"Move the add row to the bottom\" is waiting"))
        #expect(!words.contains("T,"))
    }

    @Test func freePromptCarriesWhatThePersonTyped() {
        let words = LaunchPrompt.free("You're the browser owner.", as: "A7")
        #expect(words.contains("agent_id \"A7\""))
        #expect(words.hasSuffix("You're the browser owner."))
    }
}
