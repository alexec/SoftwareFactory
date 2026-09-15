import Foundation
import Testing
@testable import SoftwareFactoryKit

/// Every agent's report in one place. (T288.)
@Suite struct StatusReportBoardTests {
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private var hour: TimeInterval { Artifacts.statusReportStandsFor }

    private func agent(_ number: Int, on project: Project?, registered: Date) -> Agent {
        var a = Agent(number: number, projectID: project?.id, registered: registered)
        a.lastSeen = registered
        return a
    }

    private func report(by agent: Agent, on project: Project, at date: Date) throws -> Artifact {
        try Artifacts.add(
            projectID: project.id, title: "Status", body: "Going well.", kind: .statusReport,
            agentID: agent.id, addedBy: agent.label, in: [], at: date).artifact
    }

    @Test func latestNewsFirstAndTheSilentOnesAtTheBottom() throws {
        let project = Project(name: "Software Factory")
        let quiet = agent(1, on: project, registered: now - hour * 3)
        let old = agent(2, on: project, registered: now - hour * 3)
        let fresh = agent(3, on: project, registered: now - hour * 3)
        let rows = StatusReportBoard.rows(
            in: Snapshot(
                projects: [project],
                artifacts: [
                    try report(by: old, on: project, at: now - hour * 2),
                    try report(by: fresh, on: project, at: now - 60),
                ],
                agents: [quiet, old, fresh]),
            now: now)
        #expect(rows.map(\.agent.label) == ["A3", "A2", "A1"])
        #expect(rows[0].isFresh)
        #expect(rows[0].projectName == "Software Factory")
        // Filed two hours ago, so the factory has already asked for another.
        #expect(!rows[1].isFresh)
        // The one that has said nothing still gets a row: that is the row you want.
        #expect(rows[2].report == nil)
        #expect(rows[2].said == nil)
        #expect(!rows[2].isFresh)
        #expect(StatusReportBoard.quiet(in: Snapshot(
            projects: [project], agents: [quiet, old, fresh]), now: now) == 3)
    }

    /// An agent on no project has no report to file and still belongs on the page: what
    /// it says is that it is sitting there with nothing to say.
    @Test func anAgentOnNoProjectStillGetsARow() {
        let a = agent(1, on: nil, registered: now - hour * 3)
        let rows = StatusReportBoard.rows(in: Snapshot(agents: [a]), now: now)
        #expect(rows.count == 1)
        #expect(rows[0].projectName == nil)
        #expect(rows[0].report == nil)
    }

    /// An agent whose process has gone is off the floor, and so is off this page: its
    /// report is history, and the page is for what is happening now.
    @Test func anAgentThatHasExitedIsNotOnTheBoard() throws {
        let project = Project(name: "Software Factory")
        var a = agent(1, on: project, registered: now - hour * 3)
        a.pid = 1
        a.pidStartedAt = Date(timeIntervalSince1970: 1)
        #expect(a.hasExited)
        let filed = try report(by: a, on: project, at: now - 60)
        let rows = StatusReportBoard.rows(
            in: Snapshot(projects: [project], artifacts: [filed], agents: [a]), now: now)
        #expect(rows.isEmpty)
    }

    /// A report the person took off the project leaves the agent reading as silent, which
    /// is what it is. (T266 and T288 together.)
    @Test func aDeletedReportLeavesTheAgentReadingAsSilent() throws {
        let project = Project(name: "Software Factory")
        let a = agent(1, on: project, registered: now - hour * 3)
        let filed = try report(by: a, on: project, at: now - 60)
        let gone = Artifacts.remove(filed, why: "by Alex, in the app", at: now)
        let rows = StatusReportBoard.rows(
            in: Snapshot(projects: [project], artifacts: [gone], agents: [a]), now: now)
        #expect(rows.count == 1)
        #expect(rows[0].report == nil)
        #expect(!rows[0].isFresh)
    }
}

/// The row carries the project as something to open, and only when there is one to open.
/// (T338.)
@Suite struct StatusReportBoardProjectTests {
    @Test func theRowCarriesTheProjectItNames() throws {
        let project = Project(name: "Sleeper Train")
        var agent = Agent(number: 1, projectID: project.id, registered: .now)
        agent.lastSeen = .now
        let row = try #require(StatusReportBoard.rows(
            in: Snapshot(projects: [project], agents: [agent]), now: .now).first)
        #expect(row.projectName == "Sleeper Train")
        #expect(row.projectID == project.id)
    }

    /// An agent keeps the projectID of a project that has been removed. The name is
    /// already left off such a row, and the id has to go with it, or clicking the row
    /// opens a page about a project that is not in load() any more.
    @Test func aRemovedProjectLeavesNothingToOpen() throws {
        var project = Project(name: "Sleeper Train")
        project.removed = .now
        var agent = Agent(number: 1, projectID: project.id, registered: .now)
        agent.lastSeen = .now
        let row = try #require(StatusReportBoard.rows(
            in: Snapshot(projects: [project], agents: [agent]), now: .now).first)
        #expect(row.projectName == nil)
        #expect(row.projectID == nil)
        #expect(agent.projectID != nil)
    }

    @Test func anAgentOnNoProjectHasNoProject() throws {
        var agent = Agent(number: 1, projectID: nil, registered: .now)
        agent.lastSeen = .now
        let row = try #require(StatusReportBoard.rows(in: Snapshot(agents: [agent]), now: .now).first)
        #expect(row.projectID == nil)
    }
}

/// The agents on one project, for the sidebar row they hang under. (T359.)
@Suite struct AgentsOnAProjectTests {
    private func agent(_ number: Int, on projectID: String?, stopped: Bool = false) -> Agent {
        var a = Agent(number: number, projectID: projectID, registered: .now)
        a.lastSeen = .now
        if stopped {
            // A process the factory knows and the kernel says has gone.
            a.pid = 0x7FFF_FFFE
            a.pidStartedAt = .now
        }
        return a
    }

    @Test func workingOnesFirstThenStopped() {
        let project = Project(name: "Sleeper Train")
        let gone = agent(1, on: project.id, stopped: true)
        let working = agent(2, on: project.id)
        let board = Dashboard.make(
            snapshot: Snapshot(projects: [project], agents: [gone, working]), now: .now)
        let mine = board.agents(on: project.id)
        #expect(mine.map(\.agent.number) == [2, 1])
        #expect(mine.last?.activity == .stopped)
    }

    @Test func onlyThatProjectsAgents() {
        let here = Project(name: "Sleeper Train")
        let there = Project(name: "Hold Still")
        let mine = agent(1, on: here.id)
        let theirs = agent(2, on: there.id)
        let loose = agent(3, on: nil)
        let board = Dashboard.make(
            snapshot: Snapshot(projects: [here, there], agents: [mine, theirs, loose]), now: .now)
        #expect(board.agents(on: here.id).map(\.agent.number) == [1])
        #expect(board.agents(on: there.id).map(\.agent.number) == [2])
    }

    /// Nil is the agents on no project, which hang under that row the same way.
    @Test func noProjectIsAskedForWithNil() {
        let project = Project(name: "Sleeper Train")
        let loose = agent(3, on: nil)
        let board = Dashboard.make(
            snapshot: Snapshot(projects: [project], agents: [agent(1, on: project.id), loose]),
            now: .now)
        #expect(board.agents(on: nil).map(\.agent.number) == [3])
    }

    @Test func aProjectWithNobodyOnItHasNobody() {
        let project = Project(name: "Sleeper Train")
        let board = Dashboard.make(snapshot: Snapshot(projects: [project]), now: .now)
        #expect(board.agents(on: project.id).isEmpty)
    }
}
