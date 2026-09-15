import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct AgentLineTests {
    private func report(_ body: String, title: String = "A7 status report") -> Artifact {
        Artifact(projectID: "/p", title: title, body: body)
    }

    @Test func theTaskItIsOnComesFirst() {
        var task = FactoryTask(projectID: "/p", title: "Fix the bell", rank: 0)
        task.state = .inProgress
        let line = AgentLine.underTheName(
            task: task, report: report("Halfway through the hook."), title: "✳ Wrangling tmux")
        #expect(line == "Fix the bell")
    }

    @Test func withNoTaskTheReportSpeaksForIt() {
        let line = AgentLine.underTheName(
            task: nil, report: report("## Now\nWriting the launch post."), title: "✳ Wrangling tmux")
        #expect(line == "Now")
    }

    @Test func markdownMarksAreTakenOffTheFront() {
        #expect(AgentLine.news(in: report("- - looking at the store")) == "looking at the store")
        #expect(AgentLine.news(in: report("\n\n   > quoted news")) == "quoted news")
    }

    @Test func anEmptyReportFallsBackToItsTitle() {
        #expect(AgentLine.news(in: report("   \n\n", title: "Nothing yet")) == "Nothing yet")
        #expect(AgentLine.news(in: report("", title: "  ")) == nil)
    }

    @Test func withNeitherItIsTheTerminalTitle() {
        #expect(AgentLine.underTheName(task: nil, report: nil, title: " ✳ Wrangling tmux ")
                == "✳ Wrangling tmux")
        #expect(AgentLine.underTheName(task: nil, report: nil, title: "").isEmpty)
    }

    @Test func aTaskWithNoTitleDoesNotBlankTheRow() {
        let task = FactoryTask(projectID: "/p", title: "   ", rank: 0)
        #expect(AgentLine.underTheName(task: task, report: nil, title: "✳ Something") == "✳ Something")
    }
}
