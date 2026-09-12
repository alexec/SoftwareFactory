import Foundation

/// Everything in the store, read in one go.
public struct Snapshot: Sendable, Equatable {
    public var projects: [Project]
    public var tasks: [FactoryTask]
    public var escalations: [Escalation]
    public var agents: [Agent]

    public init(projects: [Project] = [], tasks: [FactoryTask] = [], escalations: [Escalation] = [], agents: [Agent] = []) {
        self.projects = projects
        self.tasks = tasks
        self.escalations = escalations
        self.agents = agents
    }
}

/// The shared store: one JSON file per record, in a folder every app and the MCP server
/// can reach. One file per record means two writers rarely touch the same file, and every
/// write is atomic, so a half-written record is never read.
///
/// Layout:
///
///     <root>/projects/<path-hash>.json
///     <root>/tasks/<uuid>.json
///     <root>/escalations/<uuid>.json
///     <root>/agents/<uuid>.json
public struct FileStore: Sendable {
    public static let appGroup = "6T4RVD5724.com.alexecollins.foreman"

    public let root: URL

    public init(root: URL) throws {
        self.root = root
        for folder in ["projects", "tasks", "escalations", "agents"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: folder), withIntermediateDirectories: true)
        }
    }

    /// Where the store lives when nothing says otherwise: the app group container, which
    /// the sandboxed app and the unsandboxed server both resolve to the same folder.
    /// `FOREMAN_STORE` in the environment overrides it.
    public static func defaultRoot(home: URL? = nil) -> URL {
        if let override = ProcessInfo.processInfo.environment["FOREMAN_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = home ?? realHomeDirectory()
        return home
            .appending(path: "Library/Group Containers")
            .appending(path: appGroup)
            .appending(path: "Store", directoryHint: .isDirectory)
    }

    /// The user's home even from inside a sandbox, where `NSHomeDirectory` is the container.
    public static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: Reading

    public func load() throws -> Snapshot {
        Snapshot(
            projects: try loadAll("projects"),
            tasks: try loadAll("tasks"),
            escalations: try loadAll("escalations"),
            agents: try loadAll("agents")
        )
    }

    public func escalation(_ id: UUID) -> Escalation? {
        let url = root.appending(path: "escalations").appending(path: id.uuidString + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Escalation.self, from: data)
    }

    private func loadAll<T: Decodable>(_ folder: String) throws -> [T] {
        let dir = root.appending(path: folder)
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        var out: [T] = []
        for file in files where file.pathExtension == "json" {
            // A file another process is still writing, or one someone hand-edited badly,
            // is skipped rather than taking the whole store down with it.
            if let data = try? Data(contentsOf: file),
               let record = try? Self.decoder.decode(T.self, from: data) {
                out.append(record)
            }
        }
        return out
    }

    // MARK: Writing

    public func save(_ project: Project) throws {
        try write(project, to: "projects", name: Self.fileName(forProject: project.id))
    }

    public func save(_ task: FactoryTask) throws {
        try write(task, to: "tasks", name: task.id.uuidString)
    }

    public func save(_ escalation: Escalation) throws {
        try write(escalation, to: "escalations", name: escalation.id.uuidString)
    }

    public func save(_ agent: Agent) throws {
        try write(agent, to: "agents", name: agent.id.uuidString)
    }

    public func delete(_ task: FactoryTask) throws {
        try remove("tasks", name: task.id.uuidString)
    }

    public func delete(_ escalation: Escalation) throws {
        try remove("escalations", name: escalation.id.uuidString)
    }

    public func delete(_ project: Project) throws {
        try remove("projects", name: Self.fileName(forProject: project.id))
    }

    public func delete(_ agent: Agent) throws {
        try remove("agents", name: agent.id.uuidString)
    }

    private func write<T: Encodable>(_ record: T, to folder: String, name: String) throws {
        let url = root.appending(path: folder).appending(path: name + ".json")
        let data = try Self.encoder.encode(record)
        try data.write(to: url, options: .atomic)
    }

    private func remove(_ folder: String, name: String) throws {
        let url = root.appending(path: folder).appending(path: name + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// A project's file is named from its path so the same folder always lands in the
    /// same file, whoever writes it. FNV-1a keeps this Foundation-only.
    static func fileName(forProject path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Codecs

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
