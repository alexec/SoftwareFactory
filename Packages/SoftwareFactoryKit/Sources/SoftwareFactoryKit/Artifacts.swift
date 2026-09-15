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
        case statusReport

        /// What it is called where a person reads it.
        public var title: String {
            switch self {
            case .note: return "Note"
            case .statusReport: return "Status report"
            }
        }
    }

    public var version = Records.version
    public var id: UUID
    public var projectID: String
    public var title: String
    public var body: String
    public var kind: Kind
    /// Optional http or https URL this document is, when it was filed from a link.
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

    public init(
        id: UUID = UUID(), projectID: String, title: String, body: String = "", kind: Kind = .note,
        link: String = "",
        taskID: UUID? = nil, agentID: UUID? = nil, addedBy: String = "agent", added: Date = .now
    ) {
        self.id = id
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
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
    }
}

/// How artifacts are filed: twenty live notes on a project, and adding the same title
/// or the same link again returns the one already there. Status reports sit outside that
/// twenty: there is only ever one per agent, so they cap themselves, and counting them
/// in would let a busy floor's reports crowd out the documents the project is for.
public enum Artifacts {
    public static let cap = 20
    public static let fullMessage = "Twenty documents is the cap for a project. Status reports do not count."
    public static let maxBody = 100_000

    public static func live(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        artifacts
            .filter { $0.projectID == projectID && $0.removed == nil }
            .sorted { $0.added > $1.added }
    }

    /// The ordinary documents: what the cap of twenty counts.
    public static func notes(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        live(for: projectID, in: artifacts).filter { $0.kind == .note }
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
        let live = live(for: projectID, in: artifacts).filter { $0.kind == .note }
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
        in artifacts: [Artifact], at date: Date = .now
    ) throws(AddError) -> (artifact: Artifact, outcome: Outcome) {
        let validated: String
        do {
            validated = try Escalation.validatedLink(link.isEmpty ? nil : link)
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
            existing.title = title
            existing.body = body
            existing.link = validated
            existing.kind = kind
            if let taskID { existing.taskID = taskID }
            existing.addedBy = addedBy
            existing.updated = date
            return (existing, .replaced)
        }

        // Status reports cap themselves at one per agent, so they are not counted here.
        if kind == .note {
            guard notes(for: projectID, in: artifacts).count < cap else { throw .atCap }
        }
        return (Artifact(
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
                artifact.link = try Escalation.validatedLink(link.isEmpty ? nil : link)
            } catch {
                throw .badLink
            }
        }
        artifact.updated = date
        return artifact
    }

    public static func remove(_ artifact: Artifact, why: String, at date: Date = .now) -> Artifact {
        var artifact = artifact
        artifact.removed = date
        artifact.updated = date
        artifact.removedWhy = why.trimmingCharacters(in: .whitespacesAndNewlines)
        return artifact
    }

    /// Host and path, so a URL becomes a title a person can read.
    public static func title(fromLink raw: String) -> String {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
