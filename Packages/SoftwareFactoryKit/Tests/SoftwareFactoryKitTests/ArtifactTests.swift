import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct ArtifactTests {
    @Test func addIsIdempotentOnTitleAndOnLink() throws {
        let project = "/p"
        let first = try Artifacts.add(projectID: project, title: "Login", body: "A brief.", in: [])
        #expect(first.created)
        let again = try Artifacts.add(
            projectID: project, title: "login", body: "A different body.", in: [first.artifact])
        #expect(!again.created)
        #expect(again.artifact.id == first.artifact.id)
        #expect(again.artifact.body == "A brief.")

        let fromLink = try Artifacts.add(
            projectID: project, title: "", link: "https://example.com/weather.md", in: [first.artifact])
        #expect(fromLink.created)
        #expect(fromLink.artifact.title == "example.com/weather.md")
        let sameLink = try Artifacts.add(
            projectID: project, title: "Weather", link: "https://example.com/weather.md",
            in: [first.artifact, fromLink.artifact])
        #expect(!sameLink.created)
        #expect(sameLink.artifact.id == fromLink.artifact.id)
    }

    @Test func twentyIsTheCapAndAMatchDoesNotCountAsNew() throws {
        var live: [Artifact] = []
        for n in 1...Artifacts.cap {
            let result = try Artifacts.add(projectID: "/p", title: "Doc \(n)", in: live)
            #expect(result.created)
            live.append(result.artifact)
        }
        #expect(throws: Artifacts.AddError.atCap) {
            try Artifacts.add(projectID: "/p", title: "One more", in: live)
        }
        let again = try Artifacts.add(projectID: "/p", title: "Doc 1", in: live)
        #expect(!again.created)
        #expect(live.count == Artifacts.cap)

        let other = try Artifacts.add(projectID: "/q", title: "Doc 1", in: live)
        #expect(other.created)
    }

    @Test func aRemovedArtifactFreesTheTitleAndDoesNotCount() throws {
        let added = try Artifacts.add(projectID: "/p", title: "Login", body: "v1", in: [])
        let gone = Artifacts.remove(added.artifact, why: "superseded")
        #expect(gone.removed != nil)
        #expect(Artifacts.live(for: "/p", in: [gone]).isEmpty)
        let next = try Artifacts.add(projectID: "/p", title: "Login", body: "v2", in: [gone])
        #expect(next.created)
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

    @Test func titleFromALinkDropsWwwAndKeepsThePath() {
        #expect(Artifacts.title(fromLink: "https://www.example.com/brief.md") == "example.com/brief.md")
        #expect(Artifacts.title(fromLink: "https://example.com/") == "example.com")
    }
}
