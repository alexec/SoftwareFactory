import Foundation

/// A document an agent puts on a project for the person to read. Design briefs, plans,
/// findings: anything that should live here rather than only as a URL. Referenced from
/// a question when they should read it before they choose.
public struct Artifact: Codable, Identifiable, Hashable, Sendable {
    public var version = Records.version
    public var id: UUID
    public var projectID: String
    public var title: String
    public var body: String
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
        id: UUID = UUID(), projectID: String, title: String, body: String = "", link: String = "",
        taskID: UUID? = nil, agentID: UUID? = nil, addedBy: String = "agent", added: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
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

/// How artifacts are filed: twenty live ones on a project, and adding the same title
/// or the same link again returns the one already there.
public enum Artifacts {
    public static let cap = 20
    public static let fullMessage = "Twenty artifacts is the cap for a project."
    public static let maxBody = 100_000

    public static func live(for projectID: String, in artifacts: [Artifact]) -> [Artifact] {
        artifacts
            .filter { $0.projectID == projectID && $0.removed == nil }
            .sorted { $0.added > $1.added }
    }

    public static func produced(by agentID: UUID, in artifacts: [Artifact]) -> [Artifact] {
        artifacts
            .filter { $0.agentID == agentID && $0.removed == nil }
            .sorted { $0.added > $1.added }
    }

    /// The live one on this project with this link, or this title. Link wins: the same
    /// URL is the same document even if the titles would differ.
    public static func matching(projectID: String, title: String, link: String, in artifacts: [Artifact]) -> Artifact? {
        let live = live(for: projectID, in: artifacts)
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

    /// Creates one, or returns the live one that already has this title or this link.
    /// A missing title is taken from the link when there is one, so filing a URL is
    /// enough. The cap applies only to a new record.
    public static func add(
        projectID: String, title: String, body: String = "", link: String = "",
        taskID: UUID? = nil, agentID: UUID? = nil, addedBy: String = "agent",
        in artifacts: [Artifact], at date: Date = .now
    ) throws(AddError) -> (artifact: Artifact, created: Bool) {
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
        if let existing = matching(projectID: projectID, title: title, link: validated, in: artifacts) {
            return (existing, false)
        }
        guard live(for: projectID, in: artifacts).count < cap else { throw .atCap }
        return (Artifact(
            projectID: projectID, title: title, body: body, link: validated,
            taskID: taskID, agentID: agentID, addedBy: addedBy, added: date
        ), true)
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
            let clash = live(for: artifact.projectID, in: artifacts).first {
                $0.id != artifact.id && $0.title.compare(title, options: .caseInsensitive) == .orderedSame
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
