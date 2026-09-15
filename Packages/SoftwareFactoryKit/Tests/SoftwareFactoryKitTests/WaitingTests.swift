import Testing
import Foundation
@testable import SoftwareFactoryKit

/// The two counts beside the factory's name. (T373.)
@Suite struct WaitingTests {
    private func project(_ name: String, removed: Date? = nil) -> Project {
        var p = Project(name: name)
        p.removed = removed
        return p
    }

    private func document(on projectID: String, read: Bool, removed: Date? = nil) -> Artifact {
        var a = Artifact(projectID: projectID, title: "A plan", body: "Words", agentID: UUID())
        if read { a.readAt = Date() }
        a.removed = removed
        return a
    }

    @Test func onlyDocumentsNobodyHasOpenedCount() {
        let here = project("Sleeper Train")
        let gone = project("NightSleeper", removed: Date())
        let artifacts = [
            document(on: here.id, read: false),
            document(on: here.id, read: true),
            document(on: here.id, read: false, removed: Date()),
            // On a project that has been removed: nobody is going to read it.
            document(on: gone.id, read: false),
        ]
        #expect(Waiting.unreadDocuments(artifacts, on: [here, gone]) == 1)
    }

    @Test func onlyMessagesStillWaitingForAnAgentThatIsHereCount() {
        var here = Agent(projectID: nil)
        here.lastSeen = Date()
        var gone = Agent(projectID: nil)
        gone.deregistered = Date()
        let messages = [
            AgentMessage(recipientID: here.id, from: "A1", subject: "", contents: "Have a look"),
            AgentMessage(recipientID: here.id, from: "A1", subject: "", contents: "Read", delivered: Date()),
            AgentMessage(recipientID: gone.id, from: "A1", subject: "", contents: "Nobody home"),
        ]
        #expect(Waiting.messages(messages, to: [here, gone]) == 1)
    }

    @Test func nothingWaitingIsZeroRatherThanAnEmptyThing() {
        #expect(Waiting.unreadDocuments([], on: []) == 0)
        #expect(Waiting.messages([], to: []) == 0)
    }
}
