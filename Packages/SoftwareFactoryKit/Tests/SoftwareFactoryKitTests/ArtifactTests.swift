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

    /// Two kilobytes, and the refusal says what to do instead rather than only saying no.
    /// (T274, then T416: a kilobyte was tight for a status report.)
    @Test func aDocumentIsTwoKilobytesAndTheRefusalSaysWhereTheLongOneGoes() throws {
        #expect(Artifacts.maxBody == 2048)
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
        #expect(Artifacts.tooLongMessage.contains("\(Artifacts.maxBody)"))
        #expect(Artifacts.tooLongMessage.contains("link"))
    }

    @Test func titleFromALinkDropsWwwAndKeepsThePath() {
        #expect(Artifacts.title(fromLink: "https://www.example.com/brief.md") == "example.com/brief.md")
        #expect(Artifacts.title(fromLink: "https://example.com/") == "example.com")
    }
}

/// A document is one of three things now: the body an agent typed, a page on the web, or
/// a markdown or HTML file on this Mac. What may be filed as a link, and what the app
/// then reads it from. (T311.)
@Suite struct ArtifactSourceTests {
    @Test func noLinkIsTheBody() {
        #expect(Artifacts.source(ofLink: "") == .text)
        #expect(Artifacts.source(ofLink: "   ") == .text)
    }

    @Test func aWebAddressIsKeptAsTyped() throws {
        let link = try Artifacts.validatedLink("https://example.com/plan?x=1")
        #expect(link == "https://example.com/plan?x=1")
        #expect(Artifacts.source(ofLink: link) == .web(URL(string: "https://example.com/plan?x=1")!))
    }

    @Test func aTildeComesOffWhenTheFileIsFiled() throws {
        let link = try Artifacts.validatedLink("~/Work/Thing/plan.md", home: "/Users/someone")
        #expect(link == "/Users/someone/Work/Thing/plan.md")
        #expect(Artifacts.source(ofLink: link) == .file(URL(filePath: "/Users/someone/Work/Thing/plan.md")))
    }

    @Test func aFileURLIsFiledAsItsPath() throws {
        let link = try Artifacts.validatedLink("file:///Users/someone/notes/a%20plan.md")
        #expect(link == "/Users/someone/notes/a plan.md")
    }

    @Test func htmlIsAFileToo() throws {
        #expect(try Artifacts.validatedLink("/tmp/report.HTML") == "/tmp/report.HTML")
        #expect(try Artifacts.validatedLink("/tmp/report.htm") == "/tmp/report.htm")
    }

    /// Relative is no path at all: it would be read against wherever the app happened to
    /// be launched from, which is a file nobody meant. Same rule as a project's folder.
    @Test func whatIsRefused() {
        #expect(throws: Artifacts.LinkError.badLink) { try Artifacts.validatedLink("Work/plan.md") }
        #expect(throws: Artifacts.LinkError.badLink) { try Artifacts.validatedLink("~/plan.zip") }
        #expect(throws: Artifacts.LinkError.badLink) { try Artifacts.validatedLink("/Users/someone/notes") }
        #expect(throws: Artifacts.LinkError.badLink) { try Artifacts.validatedLink("ftp://example.com/plan.md") }
        #expect(throws: Artifacts.LinkError.badLink) { try Artifacts.validatedLink("https:///plan.md") }
    }

    @Test func aFileIsCalledAfterItsFile() {
        #expect(Artifacts.title(fromLink: "/Users/someone/Work/Thing/the-plan.md") == "the-plan.md")
        #expect(Artifacts.title(fromLink: "https://www.example.com/plan") == "example.com/plan")
    }

    @Test func filingAFileWithNoTitleNamesItAfterTheFile() throws {
        let (artifact, outcome) = try Artifacts.add(
            projectID: "p", title: "", link: "/Users/someone/plan.md", in: [])
        #expect(outcome == .created)
        #expect(artifact.title == "plan.md")
        #expect(artifact.source == .file(URL(filePath: "/Users/someone/plan.md")))
    }

    @Test func aBadLinkIsRefusedRatherThanFiledEmpty() {
        #expect(throws: Artifacts.AddError.badLink) {
            try Artifacts.add(projectID: "p", title: "Plan", link: "~/plan.zip", in: [])
        }
    }
}

@Suite struct ArtifactBodyWinsTests {
    @Test func aDocumentWithABodyIsItsBody() throws {
        let (artifact, _) = try Artifacts.add(
            projectID: "p", title: "The plan", body: "The short version.",
            link: "https://example.com/the-long-version", in: [])
        #expect(artifact.source == .text)
    }

    @Test func aDocumentWithNothingWrittenInItIsItsLink() throws {
        let (artifact, _) = try Artifacts.add(
            projectID: "p", title: "The plan", link: "https://example.com/plan", in: [])
        #expect(artifact.source == .web(URL(string: "https://example.com/plan")!))
    }
}

/// The two an agent reaches for that were not documents: a screenshot, and a server it
/// has running. (T317.)
@Suite struct ArtifactCommonKindsTests {
    @Test func aScreenshotIsAFileLikeAnyOther() throws {
        let link = try Artifacts.validatedLink("~/Desktop/the-floor.png", home: "/Users/someone")
        #expect(link == "/Users/someone/Desktop/the-floor.png")
        let url = URL(filePath: link)
        #expect(Artifacts.source(ofLink: link) == .file(url))
        #expect(Artifacts.isPicture(url))
    }

    @Test func picturesAndPDFsGoIn() throws {
        for name in ["/tmp/a.PNG", "/tmp/a.jpg", "/tmp/a.jpeg", "/tmp/a.gif", "/tmp/a.heic",
                     "/tmp/a.webp", "/tmp/a.svg", "/tmp/a.pdf"] {
            #expect(try Artifacts.validatedLink(name) == name)
        }
    }

    /// A document is read as words, a picture is shown as itself.
    @Test func aMarkdownFileIsNotAPicture() {
        #expect(!Artifacts.isPicture(URL(filePath: "/tmp/plan.md")))
        #expect(!Artifacts.isPicture(URL(filePath: "/tmp/report.html")))
    }

    /// A server running on this Mac is an ordinary URL and always was.
    @Test func aRunningLocalServerIsJustAURL() throws {
        #expect(try Artifacts.validatedLink("http://localhost:3000") == "http://localhost:3000")
        #expect(try Artifacts.validatedLink("http://127.0.0.1:8080/health") == "http://127.0.0.1:8080/health")
        #expect(Artifacts.source(ofLink: "http://localhost:3000")
                == .web(URL(string: "http://localhost:3000")!))
    }

    @Test func aFileOfNoKnownKindIsStillRefused() {
        #expect(throws: Artifacts.LinkError.badLink) { try Artifacts.validatedLink("/tmp/a.zip") }
        #expect(throws: Artifacts.LinkError.badLink) { try Artifacts.validatedLink("/tmp/a.mov") }
    }
}

/// What goes when an agent is deleted. Its status reports, because they are about the
/// agent; not its notes, because a plan or a finding belongs to the project. (T310.)
@Suite struct ArtifactsWhenAnAgentGoesTests {
    private func report(by agent: UUID, on project: String, called title: String) -> Artifact {
        Artifact(projectID: project, title: title, kind: .statusReport, agentID: agent)
    }

    @Test func onlyThatAgentsReports() {
        let mine = UUID()
        let theirs = UUID()
        let here = report(by: mine, on: "p", called: "How it is going")
        let elsewhere = report(by: mine, on: "q", called: "How it is going over there")
        let note = Artifact(projectID: "p", title: "The plan", body: "x", agentID: mine)
        let notMine = report(by: theirs, on: "p", called: "Theirs")

        let going = Artifacts.statusReports(by: mine, in: [here, elsewhere, note, notMine])
        #expect(Set(going.map(\.id)) == Set([here.id, elsewhere.id]))
    }

    /// A report already taken off the project still has a file on disk, and the point of
    /// this is that nothing of the agent's is left behind.
    @Test func aRemovedReportGoesToo() {
        let mine = UUID()
        let gone = Artifacts.remove(report(by: mine, on: "p", called: "Old"), why: "done with")
        #expect(Artifacts.statusReports(by: mine, in: [gone]).map(\.id) == [gone.id])
    }

    @Test func anAgentThatFiledNothingLosesNothing() {
        #expect(Artifacts.statusReports(by: UUID(), in: []).isEmpty)
    }
}

/// Read and unread. A document arrives unread, goes read when the person opens it, and
/// comes back unread when the agent has something new to say in it. (T335.)
@Suite struct ArtifactReadTests {
    @Test func aNewDocumentIsUnread() throws {
        let (artifact, _) = try Artifacts.add(projectID: "p", title: "The plan", body: "x", in: [])
        #expect(!artifact.isRead)
        #expect(artifact.readAt == nil)
    }

    @Test func openingItMarksItRead() {
        let when = Date()
        let artifact = Artifacts.read(Artifact(projectID: "p", title: "The plan"), at: when)
        #expect(artifact.isRead)
        #expect(artifact.readAt == when)
    }

    /// Reading it again is not a change to the document: `updated` is left alone, or a
    /// document would climb to the top of every list just for being looked at.
    @Test func readingItTwiceChangesNothing() {
        let first = Date(timeIntervalSince1970: 1_000)
        let artifact = Artifacts.read(Artifact(projectID: "p", title: "The plan"), at: first)
        let again = Artifacts.read(artifact, at: first.addingTimeInterval(500))
        #expect(again.readAt == first)
        #expect(again.updated == artifact.updated)
    }

    @Test func aRewrittenDocumentIsUnreadAgain() throws {
        let agent = UUID()
        let (filed, _) = try Artifacts.add(
            projectID: "p", title: "How it is going", body: "Halfway",
            kind: .statusReport, agentID: agent, in: [])
        let read = Artifacts.read(filed)
        #expect(read.isRead)

        let (again, outcome) = try Artifacts.add(
            projectID: "p", title: "How it is going", body: "Finished",
            kind: .statusReport, agentID: agent, in: [read])
        #expect(outcome == .replaced)
        #expect(!again.isRead)
    }

    /// An agent re-filing the same words has not given you anything to read.
    @Test func refilingTheSameWordsLeavesItRead() throws {
        let agent = UUID()
        let (filed, _) = try Artifacts.add(
            projectID: "p", title: "How it is going", body: "Halfway",
            kind: .statusReport, agentID: agent, in: [])
        let read = Artifacts.read(filed)
        let (again, _) = try Artifacts.add(
            projectID: "p", title: "How it is going", body: "Halfway",
            kind: .statusReport, agentID: agent, in: [read])
        #expect(again.isRead)
    }

    @Test func artifactSetMakesItUnreadWhenItSaysSomethingElse() throws {
        let read = Artifacts.read(Artifact(projectID: "p", title: "The plan", body: "x"))
        #expect(try !Artifacts.set(read, body: "y", in: [read]).isRead)
        #expect(try Artifacts.set(read, body: "x", in: [read]).isRead)
        #expect(try !Artifacts.set(read, title: "Another plan", in: [read]).isRead)
    }

    @Test func unreadOnAProject() {
        let read = Artifacts.read(Artifact(projectID: "p", title: "Seen"))
        let fresh = Artifact(projectID: "p", title: "Not seen")
        let elsewhere = Artifact(projectID: "q", title: "Somewhere else")
        #expect(Artifacts.unread(for: "p", in: [read, fresh, elsewhere]).map(\.id) == [fresh.id])
    }

    /// A document filed before the flag existed reads as unread: it carries no evidence
    /// that anybody read it, and guessing the other way hides something nobody has seen.
    @Test func anOlderRecordIsUnread() throws {
        let old = """
        {"version":3,"id":"\(UUID().uuidString)","projectID":"p","title":"Old",
         "body":"x","added":"2026-09-01T10:00:00Z"}
        """
        let artifact = try FileStore.decoder.decode(Artifact.self, from: Data(old.utf8))
        #expect(!artifact.isRead)
    }
}

/// R numbers: a short name a person can say for a document, the same idea as a task's
/// T509. (T341.)
@Suite struct ArtifactNumberTests {
    @Test func aNewDocumentGetsTheNextNumber() throws {
        let (first, _) = try Artifacts.add(projectID: "p", title: "One", in: [])
        #expect(first.number == 1)
        #expect(first.label == "R1")
        let (second, _) = try Artifacts.add(projectID: "p", title: "Two", in: [first])
        #expect(second.label == "R2")
    }

    /// Unique across every project, like a task's number, so R12 names one document
    /// wherever it was filed.
    @Test func numbersAreUniqueAcrossProjects() throws {
        let (here, _) = try Artifacts.add(projectID: "p", title: "One", in: [])
        let (there, _) = try Artifacts.add(projectID: "q", title: "Two", in: [here])
        #expect(here.number == 1 && there.number == 2)
    }

    @Test func saidAnyWay() {
        let one = Artifact(number: 12, projectID: "p", title: "Twelve")
        let all = [one, Artifact(number: 3, projectID: "p", title: "Three")]
        for said in ["R12", "r12", "12", " R12 "] {
            #expect(Artifacts.artifact(numbered: said, in: all)?.id == one.id)
        }
        #expect(Artifacts.artifact(numbered: "R99", in: all) == nil)
        #expect(Artifacts.artifact(numbered: "plan", in: all) == nil)
    }

    /// A number is never reused, so the count has to include documents taken off the
    /// project and documents on a project that has been removed.
    @Test func aRemovedDocumentKeepsItsNumber() {
        let gone = Artifacts.remove(Artifact(number: 7, projectID: "p", title: "Old"), why: "done")
        #expect(Artifacts.nextNumber(in: [gone]) == 8)
    }

    @Test func replacingADocumentKeepsItsNumber() throws {
        let agent = UUID()
        let (filed, _) = try Artifacts.add(
            projectID: "p", title: "How it is going", body: "Halfway",
            kind: .statusReport, agentID: agent, in: [])
        let (again, outcome) = try Artifacts.add(
            projectID: "p", title: "How it is going", body: "Finished",
            kind: .statusReport, agentID: agent, in: [filed])
        #expect(outcome == .replaced)
        #expect(again.number == filed.number)
    }

    @Test func aDocumentFiledBeforeNumbersHasNone() throws {
        let old = """
        {"version":3,"id":"\(UUID().uuidString)","projectID":"p","title":"Old",
         "body":"x","added":"2026-09-01T10:00:00Z"}
        """
        let artifact = try FileStore.decoder.decode(Artifact.self, from: Data(old.utf8))
        #expect(artifact.number == nil)
        #expect(artifact.label == nil)
    }
}

/// A brief: what the work is, before it is done. It is the project's document like a
/// note, and counts against the same twenty. (T350.)
@Suite struct ArtifactBriefTests {
    @Test func aBriefIsTheProjectsAndAReportIsTheAgentsOwn() {
        #expect(Artifact.Kind.note.isProjectDocument)
        #expect(Artifact.Kind.brief.isProjectDocument)
        #expect(!Artifact.Kind.statusReport.isProjectDocument)
        #expect(Artifact.Kind.brief.title == "Brief")
    }

    @Test func briefsAndNotesShareTheCap() throws {
        var filed: [Artifact] = []
        for n in 1...Artifacts.cap {
            let (a, _) = try Artifacts.add(
                projectID: "p", title: "Thing \(n)", kind: n.isMultiple(of: 2) ? .brief : .note,
                in: filed)
            filed.append(a)
        }
        #expect(Artifacts.documents(for: "p", in: filed).count == Artifacts.cap)
        #expect(throws: Artifacts.AddError.atCap) {
            try Artifacts.add(projectID: "p", title: "One too many", kind: .brief, in: filed)
        }
        // A status report still gets in: it caps itself at one per agent.
        #expect(throws: Never.self) {
            try Artifacts.add(projectID: "p", title: "How it is going",
                              kind: .statusReport, agentID: UUID(), in: filed)
        }
    }

    /// The same title is the same document whichever kind it was filed as, or a project
    /// could hold two things called The Plan.
    @Test func aBriefAndANoteWithOneTitleAreOneDocument() throws {
        let (note, _) = try Artifacts.add(projectID: "p", title: "The plan", body: "x", in: [])
        let (again, outcome) = try Artifacts.add(
            projectID: "p", title: "The plan", body: "y", kind: .brief, in: [note])
        #expect(outcome == .alreadyThere)
        #expect(again.id == note.id)
    }

    @Test func theyAreListedApart() throws {
        let (note, _) = try Artifacts.add(projectID: "p", title: "A finding", in: [])
        let (brief, _) = try Artifacts.add(projectID: "p", title: "What we are building",
                                           kind: .brief, in: [note])
        let all = [note, brief]
        #expect(Artifacts.notes(for: "p", in: all).map(\.id) == [note.id])
        #expect(Artifacts.briefs(for: "p", in: all).map(\.id) == [brief.id])
        #expect(Artifacts.documents(for: "p", in: all).count == 2)
    }

    /// Written before briefs existed, so it is a note, which is what it always was.
    @Test func anOlderRecordIsStillANote() throws {
        let old = """
        {"version":3,"id":"\(UUID().uuidString)","projectID":"p","title":"Old",
         "body":"x","added":"2026-09-01T10:00:00Z"}
        """
        #expect(try FileStore.decoder.decode(Artifact.self, from: Data(old.utf8)).kind == .note)
    }
}
