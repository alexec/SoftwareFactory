import Foundation

/// A document an agent puts on a project for the person to read. Design briefs, plans,
/// findings: anything that should live here rather than only as a URL. Referenced from
/// a question when they should read it before they choose.
public struct Artifact: Codable, Identifiable, Hashable, Sendable {
    /// What kind of document this is. A note is the ordinary thing an agent files: a
    /// brief, a plan, a finding, and there can be as many as the project needs. A status
    /// report is the one document an agent keeps about its own work, and there is only
    /// ever one of them per agent, replaced each time rather than added to: a pile of
    /// hourly reports is a log, and nobody reads a log to find out how the work is
    /// going. (Alex, 15 Sep 2026.)
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case note
        /// What the work is, before it is done: the thing a design task produces and a
        /// plan task builds on. A note is whatever an agent wanted to write down; a
        /// brief is the one you read before you decide to go ahead, and worth being able
        /// to pick out of a pile of twenty. (T350, Alex, 15 Sep 2026.)
        case brief
        case statusReport

        /// What it is called where a person reads it.
        public var title: String {
            switch self {
            case .note: return "Note"
            case .brief: return "Brief"
            case .statusReport: return "Status report"
            }
        }

        /// Whether it belongs to the project rather than to the agent that wrote it. A
        /// note and a brief do, and the cap of twenty counts them; a status report is
        /// one agent's own and caps itself at one.
        public var isProjectDocument: Bool { self != .statusReport }
    }

    /// What this document actually is. An agent types a note and the body is the
    /// document; it files a URL and the page is the document; it files the path of a
    /// file in the repo and that file is the document. All three are read the same way,
    /// as a page on paper, so the person never has to know which one they opened.
    /// (T311, 15 Sep 2026.)
    public enum Source: Equatable, Sendable {
        /// The body, as markdown.
        case text
        /// A page on the web.
        case web(URL)
        /// A markdown or HTML file on this Mac.
        case file(URL)
    }

    public var version = Records.version
    public var id: UUID
    /// A short number people can say and type, R12, unique across every project. The
    /// same idea as a task's T509: an agent tells you to read R12 and you can find it,
    /// and you can say it back without reading out a UUID. New documents get one on the
    /// way in; documents filed before numbers existed get one the first time the app
    /// looks at them. (T341, Alex, 15 Sep 2026.)
    public var number: Int?
    public var projectID: String
    public var title: String
    public var body: String
    public var kind: Kind
    /// Optional http or https URL, or the path of a markdown or HTML file on this Mac,
    /// that this document is. A file path is stored absolute: the tilde comes off when
    /// it is filed, so nothing has to guess whose home it meant afterwards.
    public var link: String
    public var taskID: UUID?
    public var agentID: UUID?
    public var addedBy: String
    public var added: Date
    public var updated: Date
    /// Set when it was taken off the project. Nothing is deleted; it stays on disk
    /// with the reason, out of every list.
    public var removed: Date?
    public var removedWhy: String
    /// When the person read it, or nil for one nobody has opened yet.
    ///
    /// A date rather than a flag, because a flag is a date with the useful half thrown
    /// away, and `isRead` asks the flag's question anyway. Writing over a document makes
    /// it unread again: an agent that has rewritten its status report has something new
    /// to say, and a card that stayed small would be the floor going quiet exactly where
    /// there is news. (T335, Alex, 15 Sep 2026.)
    public var readAt: Date?

    public init(
        id: UUID = UUID(), number: Int? = nil, projectID: String, title: String,
        body: String = "", kind: Kind = .note,
        link: String = "",
        taskID: UUID? = nil, agentID: UUID? = nil, addedBy: String = "agent", added: Date = .now
    ) {
        self.id = id
        self.number = number
        self.projectID = projectID
        self.title = title
        self.body = body
        self.kind = kind
        self.link = link
        self.taskID = taskID
        self.agentID = agentID
        self.addedBy = addedBy
        self.added = added
        self.updated = added
        self.removedWhy = ""
    }

    /// Whether the person has opened it.
    public var isRead: Bool { readAt != nil }

    /// How it is named in a sentence: "R12", or nothing for one filed before numbers.
    public var label: String? { number.map { "R\($0)" } }

    /// Where to read it from. What somebody wrote here wins: a document with a body is
    /// that body, and its link is a reference beside it rather than the document itself.
    /// A link is the document when there is nothing else to be.
    public var source: Source {
        body.isEmpty ? Artifacts.source(ofLink: link) : .text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        projectID = try c.decode(String.self, forKey: .projectID)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        // Written after the fact: every artifact filed before status reports existed is
        // a note, which is what it always was. No version bump needed.
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .note
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID)
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
        addedBy = try c.decodeIfPresent(String.self, forKey: .addedBy) ?? "agent"
        added = try c.decode(Date.self, forKey: .added)
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? added
        removed = try c.decodeIfPresent(Date.self, forKey: .removed)
        removedWhy = try c.decodeIfPresent(String.self, forKey: .removedWhy) ?? ""
        // Every document filed before this existed reads as unread, because none of them
        // carries any evidence that it was read. Guessing the other way would hide a
        // document nobody has seen, which is the one failure that matters here; this way
        // costs a pass of opening things once. No version bump: an older reader has
        // never heard of the field and does not miss it.
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
    }
}

/// How artifacts are filed: twenty live notes on a project, and adding the same title
/// or the same link again returns the one already there. Status reports sit outside that
/// twenty: there is only ever one per agent, so they cap themselves, and counting them
/// in would let a busy floor's reports crowd out the documents the project is for.
public enum Artifacts {
    public static let cap = 20
    public static let fullMessage = "Twenty documents is the cap for a project. Status reports do not count."
    /// Said in one place, because a refusal that only says no leaves the agent to guess.
    public static var tooLongMessage: String {
        "That is too long. A document is \(maxBody) characters, four or five paragraphs:"
            + " say the short version here, and put the long one in the repo with a link to it."
    }
    /// How long a document may be. Two kilobytes, which is four or five paragraphs: an
    /// artifact is something the person reads on a card while deciding what to do, not
    /// somewhere to put a transcript. An agent with more to say than this has a file in
    /// the repo to put it in and a link to file instead.
    ///
    /// It was a kilobyte and that turned out to be tight for the thing this is most used
    /// for, a status report that says what is finished, what was decided and what it is
    /// waiting on: three short paragraphs and a list already reached it. Twice is still
    /// short enough that nobody files a transcript here. (T274, then T416, Alex,
    /// 15 Sep 2026.)
    public static let maxBody = 2048

    /// Documents: a file the app turns into a page and puts on paper.
    public static let readableFiles = ["md", "markdown", "html", "htm"]

    /// Pictures: a file the app shows as itself rather than as words. A screenshot is
    /// the one an agent has most often and could not file: a page of prose saying what
    /// the screen looked like is not the screen. (T317, Alex, 15 Sep 2026.)
    public static let pictureFiles = ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "pdf"]

    /// Every file that may be filed.
    public static var fileKinds: [String] { readableFiles + pictureFiles }

    /// Whether this link is a picture to look at rather than a document to read.
    public static func isPicture(_ url: URL) -> Bool {
        pictureFiles.contains(url.pathExtension.lowercased())
    }

    /// Said in one place, because a refusal that only says no leaves the agent guessing
    /// at which half it got wrong. A URL covers a server running on this Mac too:
    /// http://localhost:3000 is an ordinary link and always was.
    public static let badLinkMessage =
        "A link is an http or https URL, which includes a server running here such as"
        + " http://localhost:3000, or the path of a file on this Mac: markdown, HTML,"
        + " an image or a PDF."

    public enum LinkError: Error, Equatable, Sendable {
        case badLink
    }

    /// What may be filed as a document's link, in the form it is stored in.
    ///
    /// A web address is kept as it was typed. A file is kept as an absolute path: the
    /// tilde is expanded here, against the real home rather than `NSHomeDirectory`,
    /// which inside the sandbox is this app's own container and matches nothing a
    /// person means. Anything relative is no path at all, for the same reason a
    /// project's folder cannot be relative: it would be read against wherever the app
    /// was launched from. (T311.)
    public static func validatedLink(
        _ raw: String?, home: String = FileStore.realHomeDirectory().path
    ) throws(LinkError) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                guard url.host != nil else { throw .badLink }
                return text
            case "file":
                return try filePath(url.path(percentEncoded: false), home: home)
            default:
                // A Windows-style drive letter or a made-up scheme is not a document.
                // A plain path has no scheme and never arrives here.
                throw .badLink
            }
        }
        return try filePath(text, home: home)
    }

    private static func filePath(_ raw: String, home: String) throws(LinkError) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~/") {
            guard !home.isEmpty else { throw .badLink }
            path = home + path.dropFirst(1)
        }
        guard path.hasPrefix("/") else { throw .badLink }
        let url = URL(filePath: path)
        guard fileKinds.contains(url.pathExtension.lowercased()) else { throw .badLink }
        return url.path(percentEncoded: false)
    }

    /// Where a document is read from, given what was filed as its link. Nothing is asked
    /// of the disk: a path to a file on a volume that is not plugged in is still where
    /// the document lives, and the page that shows it says so itself.
    public static func source(ofLink raw: String) -> Artifact.Source {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .text }
        if text.hasPrefix("/") { return .file(URL(filePath: text)) }
        guard let url = URL(string: text), url.scheme != nil else { return .text }
        if url.isFileURL { return .file(url) }
        return .web(url)
    }

    public static func live(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        artifacts
            .filter { $0.projectID == projectID && $0.removed == nil }
            .sorted { $0.added > $1.added }
    }

    /// The project's own documents: notes and briefs, which is what the cap counts.
    public static func documents(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        live(for: projectID, in: artifacts).filter(\.kind.isProjectDocument)
    }

    /// Only the notes.
    public static func notes(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        live(for: projectID, in: artifacts).filter { $0.kind == .note }
    }

    /// Only the briefs, newest first.
    public static func briefs(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        live(for: projectID, in: artifacts).filter { $0.kind == .brief }
    }

    /// Every agent's status report on this project, newest first.
    public static func statusReports(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        live(for: projectID, in: artifacts)
            .filter { $0.kind == .statusReport }
            .sorted { $0.updated > $1.updated }
    }

    /// The one status report this agent keeps on this project, if it has filed one.
    /// There is only ever one: a new report replaces it rather than joining it.
    public static func statusReport(by agentID: UUID, on projectID: String, in artifacts: [Artifact]) -> Artifact? {
        statusReports(for: projectID, in: artifacts).first { $0.agentID == agentID }
    }

    /// How long a status report stands before the factory asks for another. An agent
    /// working through a task says nothing for long stretches, and an hour is short
    /// enough that the page is never badly out of date and long enough that being asked
    /// is not an interruption. (Alex, 15 Sep 2026.)
    public static let statusReportStandsFor: TimeInterval = 60 * 60

    /// Whether this report is recent enough that the factory should leave the agent alone.
    public static func isFresh(_ artifact: Artifact, now: Date) -> Bool {
        now.timeIntervalSince(artifact.updated) < statusReportStandsFor
    }

    /// Every status report this agent has filed, on any project, removed ones included.
    ///
    /// What goes when the agent goes. A status report is the one document that is about
    /// the agent rather than about the project: with the agent gone it is a report by
    /// nobody, sitting on the Status reports page above a name that is not on the floor
    /// any more. Its notes stay, because a plan or a finding belongs to the project and
    /// is still true whoever wrote it. (T310, Alex, 15 Sep 2026.)
    public static func statusReports(by agentID: UUID, in artifacts: [Artifact]) -> [Artifact] {
        artifacts.filter { $0.agentID == agentID && $0.kind == .statusReport }
    }

    /// What one agent has filed: its status report first, then its documents newest
    /// first. The report goes on top because it is the answer to the question you opened
    /// the agent's page to ask, and because it keeps the date it was first filed however
    /// many times it is written over, so ordering everything by `added` would sink it
    /// further down the page the longer the agent worked. (T262.)
    public static func produced(by agentID: UUID, in artifacts: [Artifact]) -> [Artifact] {
        artifacts
            .filter { $0.agentID == agentID && $0.removed == nil }
            .sorted { a, b in
                if a.kind != b.kind { return a.kind == .statusReport }
                return (a.kind == .statusReport ? a.updated : a.added)
                    > (b.kind == .statusReport ? b.updated : b.added)
            }
    }

    /// The live one on this project with this link, or this title. Link wins: the same
    /// URL is the same document even if the titles would differ.
    public static func matching(projectID: String, title: String, link: String, in artifacts: [Artifact]) -> Artifact? {
        // A note and a brief with the same title are the same document, whichever it
        // was filed as: matching on the kind too would let a project hold two.
        let live = documents(for: projectID, in: artifacts)
        let title = firstLine(title)
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.isEmpty, let found = live.first(where: { $0.link == link }) { return found }
        guard !title.isEmpty else { return nil }
        return live.first { $0.title.compare(title, options: .caseInsensitive) == .orderedSame }
    }

    public enum AddError: Error, Equatable, Sendable {
        case emptyTitle
        case bodyTooLong
        case atCap
        case badLink
    }

    /// What filing did. `alreadyThere` is the old behaviour and still the default: the
    /// same document twice is the same document, and an agent re-filing a plan it
    /// already filed should not quietly lose the version on the project.
    public enum Outcome: Equatable, Sendable {
        case created
        case replaced
        case alreadyThere
    }

    /// Creates one, replaces one, or returns the live one that already has this title or
    /// this link. A missing title is taken from the link when there is one, so filing a
    /// URL is enough. The cap applies only to a new note.
    ///
    /// What counts as the same document depends on the kind. A note is matched on its
    /// title or its link, and is only written over when `replace` is asked for. A status
    /// report is matched on the agent, whatever it is called, and is always written over:
    /// an agent has one report and this is it. (Alex, 15 Sep 2026.)
    public static func add(
        projectID: String, title: String, body: String = "", kind: Artifact.Kind = .note,
        link: String = "", replace: Bool = false,
        taskID: UUID? = nil, agentID: UUID? = nil, addedBy: String = "agent",
        number: Int? = nil,
        in artifacts: [Artifact], at date: Date = .now
    ) throws(AddError) -> (artifact: Artifact, outcome: Outcome) {
        let validated: String
        do {
            validated = try validatedLink(link.isEmpty ? nil : link)
        } catch {
            throw .badLink
        }
        var title = firstLine(title)
        if title.isEmpty { title = Self.title(fromLink: validated) }
        guard !title.isEmpty else { throw .emptyTitle }
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count <= maxBody else { throw .bodyTooLong }

        let existing: Artifact?
        let alwaysReplaces: Bool
        if kind == .statusReport, let agentID {
            existing = statusReport(by: agentID, on: projectID, in: artifacts)
            alwaysReplaces = true
        } else {
            existing = matching(projectID: projectID, title: title, link: validated, in: artifacts)
            alwaysReplaces = false
        }

        if var existing {
            guard replace || alwaysReplaces else { return (existing, .alreadyThere) }
            // Only what a person would read counts as new. Re-filing the same words, as
            // an agent does when nothing has moved on, leaves it read.
            let saysSomethingElse = existing.title != title
                || existing.body != body || existing.link != validated
            existing.title = title
            existing.body = body
            existing.link = validated
            existing.kind = kind
            if let taskID { existing.taskID = taskID }
            existing.addedBy = addedBy
            existing.updated = date
            if saysSomethingElse { existing.readAt = nil }
            return (existing, .replaced)
        }

        // Status reports cap themselves at one per agent, so they are not counted here.
        if kind.isProjectDocument {
            guard documents(for: projectID, in: artifacts).count < cap else { throw .atCap }
        }
        return (Artifact(
            number: number ?? nextNumber(in: artifacts),
            projectID: projectID, title: title, body: body, kind: kind, link: validated,
            taskID: taskID, agentID: agentID, addedBy: addedBy, added: date
        ), .created)
    }

    public enum SetError: Error, Equatable, Sendable {
        case emptyTitle
        case bodyTooLong
        case badLink
        case titleTaken
    }

    /// Changes only the fields that are passed. A new title that another live artifact
    /// on the project already has is refused.
    public static func set(
        _ artifact: Artifact, title: String? = nil, body: String? = nil, link: String? = nil,
        in artifacts: [Artifact], at date: Date = .now
    ) throws(SetError) -> Artifact {
        let was = artifact
        var artifact = artifact
        if let title {
            let title = firstLine(title)
            guard !title.isEmpty else { throw .emptyTitle }
            // Only against documents of the same kind: two agents' status reports may
            // well be called the same thing, and neither is the other.
            let clash = live(for: artifact.projectID, in: artifacts).first {
                $0.id != artifact.id && $0.kind == artifact.kind
                    && $0.title.compare(title, options: .caseInsensitive) == .orderedSame
            }
            if clash != nil { throw .titleTaken }
            artifact.title = title
        }
        if let body {
            let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count <= maxBody else { throw .bodyTooLong }
            artifact.body = body
        }
        if let link {
            do {
                artifact.link = try validatedLink(link.isEmpty ? nil : link)
            } catch {
                throw .badLink
            }
        }
        artifact.updated = date
        // Changed by an agent is something new to read, the same as a document written
        // over. Changed to what it already said is not.
        let saysSomethingElse = artifact.title != was.title
            || artifact.body != was.body || artifact.link != was.link
        if saysSomethingElse { artifact.readAt = nil }
        return artifact
    }

    /// The person has opened it. Reading it again changes nothing: the date is when
    /// they first did, and `updated` is left alone, because reading a document is not a
    /// change to the document and would otherwise push it to the top of every list that
    /// orders by it.
    public static func read(_ artifact: Artifact, at date: Date = .now) -> Artifact {
        guard artifact.readAt == nil else { return artifact }
        var artifact = artifact
        artifact.readAt = date
        return artifact
    }

    /// The next reference number: one more than the highest in use anywhere. Ask it of
    /// every document on disk, `FileStore.loadEveryArtifact`, not of the snapshot, or a
    /// document on a removed project would give its number back to be used twice.
    public static func nextNumber(in all: [Artifact]) -> Int {
        (all.compactMap(\.number).max() ?? 0) + 1
    }

    /// A document by its number, said as "R12", "r12" or "12".
    public static func artifact(numbered ref: String, in all: [Artifact]) -> Artifact? {
        var digits = Substring(ref.trimmingCharacters(in: .whitespaces))
        if digits.first?.lowercased() == "r" { digits = digits.dropFirst() }
        guard let n = Int(digits) else { return nil }
        return all.first { $0.number == n }
    }

    /// The live documents on a project nobody has opened yet, newest first.
    public static func unread(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        live(for: projectID, in: artifacts).filter { !$0.isRead }
    }

    public static func remove(_ artifact: Artifact, why: String, at date: Date = .now) -> Artifact {
        var artifact = artifact
        artifact.removed = date
        artifact.updated = date
        artifact.removedWhy = why.trimmingCharacters(in: .whitespacesAndNewlines)
        return artifact
    }

    /// Host and path, so a URL becomes a title a person can read. A file is called
    /// after the file: "plan.md" is what you would say to somebody about it.
    public static func title(fromLink raw: String) -> String {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .file(let url) = source(ofLink: raw) {
            let name = url.lastPathComponent
            return name.isEmpty ? raw : name
        }
        guard let url = URL(string: raw) else { return raw }
        let host = (url.host() ?? "").replacingOccurrences(
            of: "www.", with: "", options: [.anchored, .caseInsensitive])
        let path = url.path == "/" ? "" : url.path
        let text = host + path
        return text.isEmpty ? raw : text
    }

    public static func firstLine(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }
}
