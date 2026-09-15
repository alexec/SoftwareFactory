import Foundation
import Testing
@testable import SoftwareFactoryKit

/// The factory asking an agent how it is going. An agent at work is silent, and silence
/// reads the same whether the work is going well or the agent is lost. (T262.)
@Suite struct StatusReportTests {
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private var hour: TimeInterval { Artifacts.statusReportStandsFor }

    /// An agent that has been on the floor a while and never said anything.
    private func agent(on project: Project, registered: Date, number: Int = 1) -> Agent {
        var a = Agent(number: number, projectID: project.id, registered: registered)
        a.lastSeen = registered
        return a
    }

    @Test func anAgentThatHasSaidNothingForAnHourIsAsked() {
        let project = Project(name: "Software Factory")
        let a = agent(on: project, registered: now - hour - 1)
        let wanted = Sweep.statusReportsWanted(
            in: Snapshot(projects: [project], agents: [a]), messages: [], now: now)
        #expect(wanted.messages.count == 1)
        let ask = try! #require(wanted.messages.first)
        #expect(ask.recipientID == a.id)
        #expect(ask.subject == LaunchPrompt.statusReportSubject)
        #expect(ask.contents.contains("Software Factory"))
        #expect(ask.contents.hasPrefix("Please provide a status report on your recent work"))
        #expect(wanted.agents.first?.statusAskedAt == now)
    }

    @Test func anAgentThatJustStartedIsLeftAlone() {
        let project = Project(name: "Software Factory")
        let a = agent(on: project, registered: now - 60)
        let wanted = Sweep.statusReportsWanted(
            in: Snapshot(projects: [project], agents: [a]), messages: [], now: now)
        #expect(wanted.messages.isEmpty)
        #expect(wanted.agents.isEmpty)
    }

    @Test func afreshReportStopsTheAsk() throws {
        let project = Project(name: "Software Factory")
        let a = agent(on: project, registered: now - hour * 5)
        let report = try Artifacts.add(
            projectID: project.id, title: "Status", body: "Going well.", kind: .statusReport,
            agentID: a.id, addedBy: a.label, in: [], at: now - 60).artifact
        let snap = Snapshot(projects: [project], artifacts: [report], agents: [a])
        #expect(Sweep.statusReportsWanted(in: snap, messages: [], now: now).messages.isEmpty)
        // And once it has stood for its hour, the factory asks again.
        #expect(Sweep.statusReportsWanted(in: snap, messages: [], now: now + hour).messages.count == 1)
    }

    @Test func askingTwiceInTheSameHourDoesNotHappen() {
        let project = Project(name: "Software Factory")
        var a = agent(on: project, registered: now - hour * 5)
        a.statusAskedAt = now - 60
        let snap = Snapshot(projects: [project], agents: [a])
        #expect(Sweep.statusReportsWanted(in: snap, messages: [], now: now).messages.isEmpty)
        #expect(Sweep.statusReportsWanted(in: snap, messages: [], now: now + hour).messages.count == 1)
    }

    /// A message nobody has read yet is the ask, sitting where it was left. Sending a
    /// second one is not asking harder.
    @Test func anAgentWithMailStillWaitingIsNotAsked() {
        let project = Project(name: "Software Factory")
        let a = agent(on: project, registered: now - hour * 5)
        let waiting = AgentMessage(
            recipientID: a.id, from: "Alex", subject: "A note", contents: "Have a look at this.",
            sent: now - 30)
        let snap = Snapshot(projects: [project], agents: [a])
        #expect(Sweep.statusReportsWanted(in: snap, messages: [waiting], now: now).messages.isEmpty)
        var typedIn = waiting
        typedIn.delivered = now - 20
        #expect(Sweep.statusReportsWanted(in: snap, messages: [typedIn], now: now).messages.count == 1)
    }

    /// The person can take a report off the project like any other document, and once it
    /// is gone the agent has none, so the factory asks for another. (T266.)
    @Test func aReportThePersonTookOffIsAskedForAgain() throws {
        let project = Project(name: "Software Factory")
        let a = agent(on: project, registered: now - hour * 5)
        let report = try Artifacts.add(
            projectID: project.id, title: "Status", body: "Going well.", kind: .statusReport,
            agentID: a.id, addedBy: a.label, in: [], at: now - 60).artifact
        #expect(Sweep.statusReportsWanted(
            in: Snapshot(projects: [project], artifacts: [report], agents: [a]),
            messages: [], now: now).messages.isEmpty)

        let gone = Artifacts.remove(report, why: "by Alex, in the app", at: now)
        #expect(Artifacts.statusReport(by: a.id, on: project.id, in: [gone]) == nil)
        #expect(Artifacts.live(for: project.id, in: [gone]).isEmpty)
        // And the next one the agent files is a new record, not the deleted one dug up.
        let next = try Artifacts.add(
            projectID: project.id, title: "Status", body: "Still going.", kind: .statusReport,
            agentID: a.id, addedBy: a.label, in: [gone], at: now + 1)
        #expect(next.outcome == .created)
        #expect(next.artifact.id != report.id)

        #expect(Sweep.statusReportsWanted(
            in: Snapshot(projects: [project], artifacts: [gone], agents: [a]),
            messages: [], now: now).messages.count == 1)
    }

    @Test func anAgentOnNoProjectIsNotAsked() {
        var a = Agent(number: 1, projectID: nil, registered: now - hour * 5)
        a.lastSeen = now - hour * 5
        let wanted = Sweep.statusReportsWanted(in: Snapshot(agents: [a]), messages: [], now: now)
        #expect(wanted.messages.isEmpty)
    }

    /// Only agents on the floor. One whose process has gone has nothing left to say, and
    /// its report would wait in a mailbox nobody will ever type into.
    @Test func anAgentThatHasExitedIsNotAsked() {
        let project = Project(name: "Software Factory")
        var a = agent(on: project, registered: now - hour * 5)
        a.pid = 1
        a.pidStartedAt = Date(timeIntervalSince1970: 1)
        #expect(a.hasExited)
        let wanted = Sweep.statusReportsWanted(
            in: Snapshot(projects: [project], agents: [a]), messages: [], now: now)
        #expect(wanted.messages.isEmpty)
    }

    /// Each agent is asked about the project it is actually on.
    @Test func eachAgentIsAskedAboutItsOwnProject() {
        let one = Project(name: "Software Factory")
        let two = Project(name: "Walkist")
        let a = agent(on: one, registered: now - hour * 5, number: 1)
        let b = agent(on: two, registered: now - hour * 5, number: 2)
        let wanted = Sweep.statusReportsWanted(
            in: Snapshot(projects: [one, two], agents: [a, b]), messages: [], now: now)
        #expect(wanted.messages.count == 2)
        let mine = wanted.messages.first { $0.recipientID == a.id }
        let theirs = wanted.messages.first { $0.recipientID == b.id }
        #expect(mine?.contents.contains("Software Factory") == true)
        #expect(theirs?.contents.contains("Walkist") == true)
    }
}
