import Foundation

/// Everything in the store, read in one go.
public struct Snapshot: Codable, Sendable, Equatable {
    public var projects: [Project]
    public var tasks: [FactoryTask]
    public var escalations: [Escalation]
    public var artifacts: [Artifact]
    public var agents: [Agent]
    public var resources: [Resource]
    public var leases: [Lease]

    public init(projects: [Project] = [], tasks: [FactoryTask] = [], escalations: [Escalation] = [], artifacts: [Artifact] = [],
                agents: [Agent] = [], resources: [Resource] = [], leases: [Lease] = []) {
        self.projects = projects
        self.tasks = tasks
        self.escalations = escalations
        self.artifacts = artifacts
        self.agents = agents
        self.resources = resources
        self.leases = leases
    }

    // Older snapshots (an older phone reading a newer Mac, or the reverse) may lack a field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        tasks = try c.decodeIfPresent([FactoryTask].self, forKey: .tasks) ?? []
        escalations = try c.decodeIfPresent([Escalation].self, forKey: .escalations) ?? []
        artifacts = try c.decodeIfPresent([Artifact].self, forKey: .artifacts) ?? []
        agents = try c.decodeIfPresent([Agent].self, forKey: .agents) ?? []
        resources = try c.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        leases = try c.decodeIfPresent([Lease].self, forKey: .leases) ?? []
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
///     <root>/artifacts/<uuid>.json
///     <root>/agents/<uuid>.json
///     <root>/messages/<uuid>.json
///     <root>/resources/<uuid>.json
///     <root>/leases/<uuid>.json
public struct FileStore: Sendable {
    public static let appGroup = "6T4RVD5724.com.alexecollins.softwarefactory"

    public let root: URL

    public init(root: URL) throws {
        self.root = root
        for folder in ["projects", "tasks", "escalations", "artifacts", "agents", "messages", "resources", "leases"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: folder), withIntermediateDirectories: true)
        }
    }

    /// Where the store lives when nothing says otherwise: the app group container, which
    /// the sandboxed app and the unsandboxed server both resolve to the same folder.
    /// `SOFTWARE_FACTORY_STORE` in the environment overrides it.
    public static func defaultRoot(home: URL? = nil) -> URL {
        if let override = ProcessInfo.processInfo.environment["SOFTWARE_FACTORY_STORE"], !override.isEmpty {
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
        #if os(macOS)
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        #endif
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    // MARK: Reading

    /// Removed tasks and projects stay on disk and out of the snapshot; a removed
    /// project's tasks and artifacts go with it. `loadRemovedTasks` reads the tasks back.
    public func load() throws -> Snapshot {
        // Read once and split. It read the folder twice, once for the live projects and
        // once for the removed ones, which is the same files decoded twice on a call the
        // app makes every two seconds. (T521.)
        let everyProject = try loadAll("projects") as [Project]
        let projects = everyProject.filter { $0.removed == nil }
        let live = Set(projects.map(\.id))
        let gone = Set(everyProject.filter { $0.removed != nil }.map(\.id))
        return Snapshot(
            projects: projects,
            tasks: (try loadAll("tasks") as [FactoryTask]).filter { $0.removed == nil && (live.contains($0.projectID) || !gone.contains($0.projectID)) },
            escalations: try loadAll("escalations"),
            artifacts: (try loadAll("artifacts") as [Artifact]).filter { $0.removed == nil && (live.contains($0.projectID) || !gone.contains($0.projectID)) },
            agents: try loadAll("agents"),
            resources: try loadAll("resources"),
            leases: try loadAll("leases")
        )
    }

    /// Whether anything in the store has changed, cheaply enough to ask every second.
    ///
    /// A tool that waits, `task_next` or `escalation_await`, polls until what it wants
    /// appears, and what it polled was `load()`: nine hundred files read and decoded, every
    /// second, for up to ten minutes, per waiting agent. This is the same question for a
    /// tenth of the cost, so the expensive look only happens when there is something new to
    /// look at. (R67, T524.)
    ///
    /// **Not the folders' own modification dates**, which is the obvious version and is
    /// wrong. A folder's date moves when a file is added or removed and not when one is
    /// overwritten in place, and overwriting in place is exactly what a task changing state
    /// is. A tool waiting for that would have waited for ever. Measured rather than assumed,
    /// and the assumption was mine: it was written down in R67 as the cheapest option.
    ///
    /// The count comes along because a deletion moves no date: remove a record and the
    /// newest is whatever it already was.
    public struct Stamp: Equatable, Sendable {
        public var newest: Date
        public var count: Int

        public init(newest: Date = .distantPast, count: Int = 0) {
            self.newest = newest
            self.count = count
        }
    }

    public func stamp() -> Stamp {
        var newest = Date.distantPast
        var count = 0
        for folder in Self.recordFolders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: root.appending(path: folder),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            count += files.count
            for file in files {
                // Asked for in the listing above, so this is reading what was already
                // fetched rather than a stat each.
                if let when = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, when > newest {
                    newest = when
                }
            }
        }
        return Stamp(newest: newest, count: count)
    }

    /// One agent, read from its own file.
    ///
    /// Everything that changes an agent has to read the current record first, because two
    /// writers hold the same one: the app sets a title or a pid while the server writes
    /// down what the agent just said. The way to do that was `load().agents.first(where:)`,
    /// which reads and decodes nine hundred files to answer a question about one of about
    /// five hundred bytes: 19 ms where this is microseconds. Ten places did it, one of them
    /// to read a single boolean off the record. (R67, T525.)
    ///
    /// Nothing is thrown for an agent that is not there. Every caller already had to cope
    /// with `first(where:)` finding nothing, and an agent deleted between the read and this
    /// call is the ordinary case rather than an error.
    public func loadAgent(_ id: UUID) -> Agent? {
        let file = root.appending(path: "agents").appending(path: id.uuidString + ".json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decoder.decode(Agent.self, from: data)
    }

    /// The folders `load()` reads. Named once so a stamp cannot come to cover a different
    /// set from the thing it is a stamp of.
    static let recordFolders = ["projects", "tasks", "escalations", "artifacts",
                                "agents", "resources", "leases"]

    /// The agent numbers already given out. One file per number, so taking one is
    /// atomic between the app and the server, and a deleted agent never frees its name.
    public func agentNumbers() throws -> AgentNumbers {
        try AgentNumbers(root: root)
    }

    /// The next agent number, taken and written down. A store from before the counter
    /// existed starts above the highest number its agents already carry.
    public func takeAgentNumber() throws -> Int {
        let numbers = try agentNumbers()
        let seen = try? load().agents.compactMap(\.number).max()
        return numbers.take(notBelow: seen.flatMap { $0 } ?? 0)
    }

    // MARK: Transcripts

    /// One log per agent, under the store, beside `agents/` and `tasks/`. It is the
    /// record of what an agent did: the daemon appends to it, the Mac's page folds it, and
    /// the phone reads it over HTTP. Here rather than on the daemon because the daemon is
    /// macOS only and this is the store's own folder layout, which both apps know.
    /// (T373; Alex, 16 Sep 2026.)
    public var transcriptFolder: URL {
        let folder = root.appending(path: "transcripts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public func transcriptFile(for agent: UUID) -> URL {
        transcriptFolder.appending(path: "\(agent.uuidString).jsonl")
    }

    /// Whatever the agent wrote to stderr. Not shown anywhere: it is what you read when
    /// an agent will not start and the transcript is empty, which is the one failure the
    /// protocol itself cannot describe.
    public func complaintsFile(for agent: UUID) -> URL {
        transcriptFolder.appending(path: "\(agent.uuidString).err")
    }

    /// Where a record goes when it is finished with. Beside the live folders, in the same
    /// layout, and **nothing reads it**: `load()` does not, `stamp()` does not, and a
    /// caller that wants the history asks for it by name the way `loadEveryTask()` does.
    ///
    /// Archive rather than delete is the person's decision, not a default: "nothing is
    /// lost, the reads get small, and a question about last July is answered by going to
    /// look" (Alex, escalation 80C58D5D, 17 Sep 2026). So nothing in here is ever removed
    /// by this app; emptying it is a thing a person does in the Finder, once they have
    /// decided they are finished with it, which is a decision and not a sweep.
    public func archiveFolder(_ what: String) -> URL {
        let folder = root.appending(path: "archive", directoryHint: .isDirectory)
            .appending(path: what, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An agent's log and its stderr, moved out of the way now that the agent is gone.
    ///
    /// Deleting an agent took its record and cleared the fold held in memory, and the file
    /// it was folded from stayed on the disk for ever. On this Mac that was 49 MB of log
    /// belonging to agents with no record, no page and no way to be read: a leak rather
    /// than a policy, because there was never a decision to keep them, only nothing that
    /// took them away. (R78, T555.)
    ///
    /// A name already in the archive is written over. The same agent id cannot come back
    /// (`AgentNumbers` never hands a number back either), so a collision means the same
    /// agent archived twice and the later copy is the whole of it.
    @discardableResult
    public func archiveTranscript(of agent: UUID) -> Int {
        var moved = 0
        for file in [transcriptFile(for: agent), complaintsFile(for: agent)]
        where FileManager.default.fileExists(atPath: file.path) {
            let to = archiveFolder("transcripts").appending(path: file.lastPathComponent)
            try? FileManager.default.removeItem(at: to)
            if (try? FileManager.default.moveItem(at: file, to: to)) != nil { moved += 1 }
        }
        return moved
    }

    /// Every log whose agent is no longer in the store, moved to the archive.
    ///
    /// `archiveTranscript` stops the next one being stranded; this is for the ones already
    /// stranded before it existed.
    ///
    /// **The agents it keeps come off the file names in `agents/`, not out of a snapshot.**
    /// `load()` skips a record it cannot decode, which is the right thing for drawing a
    /// screen and the wrong thing here: one unreadable agent record would read as an agent
    /// that does not exist, and this would move a working agent's conversation out from
    /// under it. A file that will not decode still has its name.
    @discardableResult
    public func archiveStrandedTranscripts() -> Int {
        let records = (try? FileManager.default.contentsOfDirectory(
            at: root.appending(path: "agents"), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let live = Set(records.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        // Nothing known means nothing to compare against: an empty or unreadable agents
        // folder must not read as a floor with nobody on it.
        guard !live.isEmpty else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: transcriptFolder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        var moved = 0
        for file in files {
            // The name is the agent's id and the extension says which of its two files it
            // is. Anything else in here was not put there by us and is left alone.
            guard ["jsonl", "err"].contains(file.pathExtension),
                  let who = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !live.contains(who) else { continue }
            let to = archiveFolder("transcripts").appending(path: file.lastPathComponent)
            try? FileManager.default.removeItem(at: to)
            if (try? FileManager.default.moveItem(at: file, to: to)) != nil { moved += 1 }
        }
        return moved
    }

    /// The lines an agent has sent, for folding into a page. A missing file is an agent
    /// that has not started rather than an error.
    public func transcriptLines(for agent: UUID) -> [String] {
        guard let text = try? String(contentsOf: transcriptFile(for: agent), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// What has been appended to an agent's log since the last read, and where to read
    /// from next.
    ///
    /// A transcript is the one record here that only ever grows, and a busy one reaches
    /// tens of megabytes in a day. Reading the whole of it to find the line that arrived a
    /// second ago is the page's largest cost by far: 30 MB measured at about 580 ms to read
    /// and fold, against one millisecond for everything the daemon is asked. So the reader
    /// keeps a byte offset and takes the tail. (T503.)
    ///
    /// Two things make this safe rather than clever. **Only whole lines are taken**: the
    /// daemon is appending while this reads, so the last line can be half written, and the
    /// offset stops at the last newline so the rest is picked up next time. And a file
    /// shorter than the offset has been started again, which is what a fresh start does, so
    /// `startedAgain` says to throw away what was folded rather than folding new lines onto
    /// an old conversation.
    public func transcriptTail(for agent: UUID, from: Int) -> TranscriptTail {
        let file = transcriptFile(for: agent)
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            // No file at all is an agent that has not started. If one had been read before,
            // it has been taken away, which is the same as being started again.
            return TranscriptTail(lines: [], next: 0, startedAgain: from > 0)
        }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let startedAgain = size < from
        let start = startedAgain ? 0 : from
        guard size > start else { return TranscriptTail(lines: [], next: start, startedAgain: startedAgain, from: start) }
        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return TranscriptTail(lines: [], next: start, startedAgain: startedAgain, from: start)
        }
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else {
            // Nothing but half a line so far. Nothing read, nothing moved on.
            return TranscriptTail(lines: [], next: start, startedAgain: startedAgain, from: start)
        }
        let whole = data[data.startIndex...lastBreak]
        let lines = String(decoding: whole, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return TranscriptTail(lines: lines, next: start + whole.count, startedAgain: startedAgain, from: start)
    }

    /// How far back a page looks when it opens.
    ///
    /// One megabyte, picked off the five biggest logs on this Mac rather than chosen: at a
    /// quarter of that the busiest page came out at three rows, and at four times it was
    /// reading a tenth of a 38 MB log for the same eleven. A megabyte is the knee.
    /// `ACPTranscript.opening` has the whole table. (T511.)
    public static let transcriptOpeningBytes = 1024 * 1024

    /// Where a page starts when it opens an agent that has been working all day.
    ///
    /// It started at the beginning, which is what a first look was. The busiest log on this
    /// Mac is 39 MB over 14,472 lines and folding it measured 235 ms, to draw the last sixty
    /// entries: thirteen thousand lines folded, sixty shown, and the page blank for the
    /// whole of it. (T503 made every read after the first one cheap and left this one
    /// alone.)
    ///
    /// **The cut is not a byte count.** Cut a log anywhere and two things break. A tool
    /// call's opening line carries its title and the updates that follow only merge into
    /// it, so a call opened above the cut comes out as a bare id in the one row somebody is
    /// looking at. And `used` and `size` come from the last `usage_update`, which may be
    /// above the cut too. So the cut goes where the agent had nothing open, which is just
    /// after a turn ended (`ACP.endsATurn`).
    ///
    /// **The rule, in one line:** the earliest turn boundary in the window with something
    /// after it, and the window doubles until there is one. Both halves matter. Earliest,
    /// because that keeps the most conversation. With something after it, because a window
    /// that catches only the last turn's ending would cut after the whole log and open the
    /// page on nothing. And when there is nothing left to widen into, the log is folded
    /// whole, which is what every log did before: an agent still on its first turn has
    /// nowhere safe to cut, and that is the honest answer rather than a guess. (T511.)
    public func transcriptOpening(for agent: UUID, want: Int = FileStore.transcriptOpeningBytes) -> TranscriptTail {
        let file = transcriptFile(for: agent)
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return TranscriptTail(lines: [], next: 0)
        }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        try? handle.close()
        guard size > 0 else { return TranscriptTail(lines: [], next: 0) }
        var window = max(want, 1)
        while true {
            let from = max(0, size - window)
            if let start = firstTurnBoundary(in: file, from: from) {
                let tail = transcriptTail(for: agent, from: start)
                if !tail.lines.isEmpty { return tail }
            }
            if from == 0 { return transcriptTail(for: agent, from: 0) }
            window *= 2
        }
    }

    /// The stretch of log immediately before what has already been folded, cut at a turn
    /// boundary so it can be folded on its own and put in front.
    ///
    /// This is scrolling back. A page opens at the end (`transcriptOpening`) and says
    /// "Earlier turns are in the log"; this is how the earlier turns come out of it, a
    /// window at a time, going backwards. `from` on the answer is where this stretch starts,
    /// which is what to pass as `before` next time. Empty lines mean the top of the log has
    /// been reached and there is nothing further back.
    ///
    /// The cut is the same rule as opening at the end, and it has to be: both ends of a
    /// stretch must fall where the agent had nothing open, or a tool call is split across
    /// the join and loses the line that names it. The far end is guaranteed because the
    /// stretch after it was cut the same way. (T542.)
    public func transcriptBefore(for agent: UUID, before: Int,
                                 want: Int = FileStore.transcriptOpeningBytes) -> TranscriptTail {
        guard before > 0 else { return TranscriptTail(lines: [], next: 0) }
        let file = transcriptFile(for: agent)
        var window = max(want, 1)
        while true {
            let from = max(0, before - window)
            if from == 0 {
                return lines(in: file, from: 0, to: before)
            }
            if let start = firstTurnBoundary(in: file, from: from, notPast: before) {
                let stretch = lines(in: file, from: start, to: before)
                if !stretch.lines.isEmpty { return stretch }
            }
            window *= 2
        }
    }

    /// Whole lines in `[from, to)`, with where they start and where they end.
    private func lines(in file: URL, from: Int, to: Int) -> TranscriptTail {
        guard to > from, let handle = try? FileHandle(forReadingFrom: file) else {
            return TranscriptTail(lines: [], next: from, from: from)
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(from))
        guard let data = try? handle.read(upToCount: to - from), !data.isEmpty else {
            return TranscriptTail(lines: [], next: from, from: from)
        }
        let text = String(decoding: data, as: UTF8.self)
        return TranscriptTail(lines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
                              next: to, from: from)
    }

    /// The first point in `[from, end)` at which a turn had just ended, as an absolute
    /// byte offset. Nil when no turn ends in that stretch.
    private func firstTurnBoundary(in file: URL, from: Int, notPast: Int? = nil) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(from))
        let data: Data?
        if let notPast {
            data = try? handle.read(upToCount: max(0, notPast - from))
        } else {
            data = try? handle.readToEnd()
        }
        guard let data, !data.isEmpty else { return nil }
        var offset = from
        var index = data.startIndex
        var isFirst = true
        while let breakAt = data[index...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = data[index...breakAt]
            let after = offset + line.count
            // A window that does not begin at the start of the file begins in the middle of
            // a line, and half a line is not a turn however it reads.
            let readable = !(isFirst && from > 0)
            if readable, ACP.endsATurn(line: String(decoding: line, as: UTF8.self)) { return after }
            isFirst = false
            offset = after
            index = data.index(after: breakAt)
        }
        return nil
    }

    /// The lines appended since last time, and where the next read starts.
    public struct TranscriptTail: Sendable, Equatable {
        public var lines: [String]
        /// The offset to pass as `from` next time. Only whole lines are counted.
        public var next: Int
        /// The log is not the one that was being read: it is shorter than where the reader
        /// had got to, so it has been started again or taken away.
        public var startedAgain: Bool
        /// Where these lines begin in the file. Zero is the top of the log, and anything
        /// else means a page folded from them starts partway through a conversation and
        /// should say so. (T511.)
        public var from: Int

        public init(lines: [String], next: Int, startedAgain: Bool = false, from: Int = 0) {
            self.lines = lines
            self.next = next
            self.startedAgain = startedAgain
            self.from = from
        }
    }

    /// Whether the transcript folder is really there and really writable. The store is a
    /// group container, and a daemon started outside the app may not be allowed into it,
    /// in which case every log would be silently empty.
    public var canKeepTranscripts: Bool {
        let folder = transcriptFolder
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder),
              isFolder.boolValue else { return false }
        return FileManager.default.isWritableFile(atPath: folder.path)
    }

    /// The throttle is one file, `throttle.json`, and the default when there is none.
    public func throttle() -> Throttle {
        let url = root.appending(path: "throttle.json")
        guard let data = try? Data(contentsOf: url), let t = try? Self.decoder.decode(Throttle.self, from: data) else { return .default }
        return t
    }

    public func save(_ throttle: Throttle) throws {
        try Self.encoder.encode(throttle).write(to: root.appending(path: "throttle.json"), options: .atomic)
    }

    /// The running app's own process, `app.json`, and nothing when the app has not
    /// written one or the store is older than this. (T271.)
    public func factoryProcess() -> FactoryProcess? {
        let url = root.appending(path: "app.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(FactoryProcess.self, from: data)
    }

    public func save(_ process: FactoryProcess) throws {
        try Self.encoder.encode(process).write(to: root.appending(path: "app.json"), options: .atomic)
    }

    public func loadRemovedTasks() throws -> [FactoryTask] {
        (try loadAll("tasks") as [FactoryTask]).filter { $0.removed != nil }
    }

    /// Every task on disk, removed or not, on a removed project or not: for numbering,
    /// so a number is never given twice.
    public func loadEveryTask() throws -> [FactoryTask] {
        try loadAll("tasks")
    }

    /// Every document on disk, removed ones and ones on removed projects included, so a
    /// reference number is never handed out twice. The same reason `loadEveryTask` exists.
    /// (T341.)
    public func loadEveryArtifact() throws -> [Artifact] {
        try loadAll("artifacts")
    }

    public func escalation(_ id: UUID) -> Escalation? {
        let url = root.appending(path: "escalations").appending(path: id.uuidString + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Escalation.self, from: data)
    }

    /// Messages belong to one recipient and are never included in the public snapshot the
    /// phone receives. The app reads them to type the undelivered ones into that agent's
    /// terminal, and to show what has been sent on its page.
    public func messages(for recipientID: UUID) throws -> [AgentMessage] {
        try (loadAll("messages") as [AgentMessage])
            .filter { $0.recipientID == recipientID }
            .sorted { $0.sent < $1.sent }
    }

    /// Every message waiting, by who it is for, in one pass over the folder.
    ///
    /// `messages(for:)` reads the whole folder and filters it, which is the right shape
    /// for one agent and the wrong one for eighty-seven: the app asked it once per agent
    /// on every refresh, so the folder was listed and decoded eighty-seven times to answer
    /// a question one pass answers. Measured at 13 ms of a 33 ms refresh, with nine
    /// messages in the folder, so nearly all of it was the listing rather than the reading.
    /// (T522.)
    public func messagesByRecipient() throws -> [UUID: [AgentMessage]] {
        var out: [UUID: [AgentMessage]] = [:]
        for message in try loadAll("messages") as [AgentMessage] {
            out[message.recipientID, default: []].append(message)
        }
        for id in out.keys {
            out[id]?.sort { $0.sent < $1.sent }
        }
        return out
    }

    /// The snapshot and every agent's mail together, which is what the app reads on its
    /// own clock and the only thing that reads both.
    public struct Everything: Sendable, Equatable {
        public var snapshot: Snapshot
        /// One entry per agent in the snapshot, oldest first. An agent with nothing
        /// waiting has an empty list rather than no entry, and mail addressed to an agent
        /// that has gone is not carried around by the floor.
        public var messages: [UUID: [AgentMessage]]

        public init(snapshot: Snapshot, messages: [UUID: [AgentMessage]]) {
            self.snapshot = snapshot
            self.messages = messages
        }
    }

    /// One read of the whole store, safe to call off the main actor: `FileStore` is a
    /// path and nothing else, so it crosses to a detached task with the rest of it.
    public func loadEverything() throws -> Everything {
        let snapshot = try load()
        let byRecipient = try messagesByRecipient()
        var mail: [UUID: [AgentMessage]] = [:]
        for agent in snapshot.agents { mail[agent.id] = byRecipient[agent.id] ?? [] }
        return Everything(snapshot: snapshot, messages: mail)
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

    public func save(_ artifact: Artifact) throws {
        try write(artifact, to: "artifacts", name: artifact.id.uuidString)
    }

    public func save(_ agent: Agent) throws {
        try write(agent, to: "agents", name: agent.id.uuidString)
    }

    public func save(_ message: AgentMessage) throws {
        try write(message, to: "messages", name: message.id.uuidString)
    }

    public func save(_ resource: Resource) throws {
        try write(resource, to: "resources", name: resource.id.uuidString)
    }

    public func save(_ lease: Lease) throws {
        try write(lease, to: "leases", name: lease.id.uuidString)
    }

    public func delete(_ resource: Resource) throws {
        try remove("resources", name: resource.id.uuidString)
    }

    public func delete(_ lease: Lease) throws {
        try remove("leases", name: lease.id.uuidString)
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

    /// A message the person has finished with. Mail is the only record nobody but its
    /// recipient reads, and once it has been typed into a terminal the copy here is a
    /// receipt: throwing one away loses nothing the agent needs. (Alex, 14 Sep 2026.)
    public func delete(_ message: AgentMessage) throws {
        try remove("messages", name: message.id.uuidString)
    }

    /// A document, off the disk rather than marked removed.
    ///
    /// `artifact_remove` is the ordinary way and it keeps the record with the reason,
    /// because a note is the project's and somebody may want to know why it went. This
    /// is for a status report whose agent has been deleted: it is about that agent and
    /// nothing else, and a tombstone naming an agent that no longer exists is a record
    /// of nothing. (T310.)
    public func delete(_ artifact: Artifact) throws {
        try remove("artifacts", name: artifact.id.uuidString)
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
