import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct ArtifactTests {
    @Test func addIsIdempotentOnTitleAndOnLink() throws {
        let project = "/p"
        let first = try Artifacts.add(projectID: project, title: "Login", body: "A brief.", in: [])
        #expect(first.outcome == .created)
        let again = try Artifacts.add(
            projectID: project, title: "login", body: "A different body.", in: [first.artifact])
        #expect(again.outcome == .alreadyThere)
        #expect(again.artifact.id == first.artifact.id)
        #expect(again.artifact.body == "A brief.")

        let fromLink = try Artifacts.add(
            projectID: project, title: "", link: "https://example.com/weather.md", in: [first.artifact])
        #expect(fromLink.outcome == .created)
        #expect(fromLink.artifact.title == "example.com/weather.md")
        let sameLink = try Artifacts.add(
            projectID: project, title: "Weather", link: "https://example.com/weather.md",
            in: [first.artifact, fromLink.artifact])
        #expect(sameLink.outcome == .alreadyThere)
        #expect(sameLink.artifact.id == fromLink.artifact.id)
    }

    @Test func twentyIsTheCapAndAMatchDoesNotCountAsNew() throws {
        var live: [Artifact] = []
        for n in 1...Artifacts.cap {
            let result = try Artifacts.add(projectID: "/p", title: "Doc \(n)", in: live)
            #expect(result.outcome == .created)
            live.append(result.artifact)
        }
        #expect(throws: Artifacts.AddError.atCap) {
            try Artifacts.add(projectID: "/p", title: "One more", in: live)
        }
        let again = try Artifacts.add(projectID: "/p", title: "Doc 1", in: live)
        #expect(again.outcome == .alreadyThere)
        #expect(live.count == Artifacts.cap)

        let other = try Artifacts.add(projectID: "/q", title: "Doc 1", in: live)
        #expect(other.outcome == .created)
    }

    @Test func aRemovedArtifactFreesTheTitleAndDoesNotCount() throws {
        let added = try Artifacts.add(projectID: "/p", title: "Login", body: "v1", in: [])
        let gone = Artifacts.remove(added.artifact, why: "superseded")
        #expect(gone.removed != nil)
        #expect(Artifacts.live(for: "/p", in: [gone]).isEmpty)
        let next = try Artifacts.add(projectID: "/p", title: "Login", body: "v2", in: [gone])
        #expect(next.outcome == .created)
        #expect(next.artifact.id != added.artifact.id)
        #expect(next.artifact.body == "v2")
    }

    @Test func setChangesOnlyWhatIsPassedAndRefusesATakenTitle() throws {
        let one = try Artifacts.add(projectID: "/p", title: "Login", body: "A", in: []).artifact
        let two = try Artifacts.add(projectID: "/p", title: "Search", body: "B", in: [one]).artifact
        let renamed = try Artifacts.set(one, title: "Sign in", in: [one, two])
        #expect(renamed.title == "Sign in")
        #expect(renamed.body == "A")
        #expect(throws: Artifacts.SetError.titleTaken) {
            try Artifacts.set(two, title: "Sign in", in: [renamed, two])
        }
        let longer = String(repeating: "x", count: Artifacts.maxBody + 1)
        #expect(throws: Artifacts.AddError.bodyTooLong) {
            try Artifacts.add(projectID: "/p", title: "Huge", body: longer, in: [])
        }
        #expect(throws: Artifacts.AddError.badLink) {
            try Artifacts.add(projectID: "/p", title: "Bad", link: "javascript:alert(1)", in: [])
        }
        #expect(throws: Artifacts.AddError.emptyTitle) {
            try Artifacts.add(projectID: "/p", title: "  ", in: [])
        }
    }

    @Test func producedByKeepsOnlyThatAgentsDocuments() throws {
        let a = UUID()
        let b = UUID()
        let mine = try Artifacts.add(
            projectID: "/p", title: "Mine", agentID: a, addedBy: "A1", in: []).artifact
        let theirs = try Artifacts.add(
            projectID: "/p", title: "Theirs", agentID: b, addedBy: "A2", in: [mine]).artifact
        #expect(Artifacts.produced(by: a, in: [mine, theirs]).map(\.id) == [mine.id])
    }

    @Test func aStatusReportReplacesTheOneThatAgentAlreadyFiled() throws {
        let agent = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = try Artifacts.add(
            projectID: "/p", title: "Where I am", body: "Reading the backlog.",
            kind: .statusReport, agentID: agent, addedBy: "A1", in: [], at: start)
        #expect(first.outcome == .created)
        #expect(first.artifact.kind == .statusReport)

        // A different title, and no replace asked for: it is still the same report,
        // because an agent has one.
        let second = try Artifacts.add(
            projectID: "/p", title: "Half way", body: "T262 is written, tests next.",
            kind: .statusReport, agentID: agent, addedBy: "A1",
            in: [first.artifact], at: start + 60)
        #expect(second.outcome == .replaced)
        #expect(second.artifact.id == first.artifact.id)
        #expect(second.artifact.title == "Half way")
        #expect(second.artifact.body == "T262 is written, tests next.")
        #expect(second.artifact.updated == start + 60)
        #expect(Artifacts.statusReports(for: "/p", in: [second.artifact]).count == 1)
    }

    @Test func anotherAgentsReportIsItsOwn() throws {
        let a = UUID()
        let b = UUID()
        let mine = try Artifacts.add(
            projectID: "/p", title: "Status", kind: .statusReport, agentID: a, addedBy: "A1",
            in: []).artifact
        let theirs = try Artifacts.add(
            projectID: "/p", title: "Status", kind: .statusReport, agentID: b, addedBy: "A2",
            in: [mine])
        #expect(theirs.outcome == .created)
        #expect(theirs.artifact.id != mine.id)
        #expect(Artifacts.statusReport(by: a, on: "/p", in: [mine, theirs.artifact])?.id == mine.id)
    }

    @Test func replaceWritesOverANoteAndWithoutItTheOldOneStands() throws {
        let first = try Artifacts.add(projectID: "/p", title: "Plan", body: "v1", in: [])
        let left = try Artifacts.add(
            projectID: "/p", title: "Plan", body: "v2", in: [first.artifact])
        #expect(left.outcome == .alreadyThere)
        #expect(left.artifact.body == "v1")

        let over = try Artifacts.add(
            projectID: "/p", title: "Plan", body: "v2", replace: true, in: [first.artifact])
        #expect(over.outcome == .replaced)
        #expect(over.artifact.id == first.artifact.id)
        #expect(over.artifact.body == "v2")
    }

    @Test func statusReportsDoNotCountTowardTheCap() throws {
        var live: [Artifact] = []
        for n in 1...Artifacts.cap {
            live.append(try Artifacts.add(projectID: "/p", title: "Doc \(n)", in: live).artifact)
        }
        #expect(throws: Artifacts.AddError.atCap) {
            try Artifacts.add(projectID: "/p", title: "One more", in: live)
        }
        let report = try Artifacts.add(
            projectID: "/p", title: "Status", kind: .statusReport, agentID: UUID(), addedBy: "A1",
            in: live)
        #expect(report.outcome == .created)
    }

    @Test func anAgentsPageShowsItsReportFirstHoweverOldTheRecordIs() throws {
        let agent = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let report = try Artifacts.add(
            projectID: "/p", title: "Status", kind: .statusReport, agentID: agent, addedBy: "A1",
            in: [], at: start).artifact
        let note = try Artifacts.add(
            projectID: "/p", title: "A plan", agentID: agent, addedBy: "A1",
            in: [report], at: start + 3600).artifact
        #expect(Artifacts.produced(by: agent, in: [report, note]).map(\.id) == [report.id, note.id])
    }

    /// A kilobyte, and the refusal says what to do instead rather than only saying no.
    /// (T274.)
    @Test func aDocumentIsAKilobyteAndTheRefusalSaysWhereTheLongOneGoes() throws {
        #expect(Artifacts.maxBody == 1024)
        let atTheLimit = String(repeating: "x", count: Artifacts.maxBody)
        #expect(try Artifacts.add(projectID: "/p", title: "Just fits", body: atTheLimit, in: [])
            .artifact.body.count == Artifacts.maxBody)
        #expect(throws: Artifacts.AddError.bodyTooLong) {
            try Artifacts.add(projectID: "/p", title: "One over", body: atTheLimit + "x", in: [])
        }
        // The same limit on the way through artifact_set, not only on the way in.
        let existing = try Artifacts.add(projectID: "/p", title: "Plan", body: "v1", in: []).artifact
        #expect(throws: Artifacts.SetError.bodyTooLong) {
            try Artifacts.set(existing, body: atTheLimit + "x", in: [existing])
        }
        #expect(Artifacts.tooLongMessage.contains("1024"))
        #expect(Artifacts.tooLongMessage.contains("link"))
    }

    @Test func titleFromALinkDropsWwwAndKeepsThePath() {
        #expect(Artifacts.title(fromLink: "https://www.example.com/brief.md") == "example.com/brief.md")
        #expect(Artifacts.title(fromLink: "https://example.com/") == "example.com")
    }
}
