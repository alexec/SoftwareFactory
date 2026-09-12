import Foundation

/// Reads Claude Code's own files to find its sessions. Nothing is written.
///
/// Two sources under `~/.claude`:
///
/// - `sessions/<pid>.json`: one file per running session, written by Claude Code when it
///   starts. It says the pid, the session id, the folder and a name.
/// - `projects/<folder>/<session-id>.jsonl`: the transcript. Its modification time is the
///   last thing the agent did; its last records say which folder the session is in now and
///   what the person last asked.
///
/// A session is live when its registry file names a process that is still running.
public struct ClaudeCodeScanner: Sendable {
    public var root: URL
    public var isProcessAlive: @Sendable (Int32) -> Bool
    /// Transcripts older than this are not read at all.
    public var recentWindow: TimeInterval
    /// How much of the end of a transcript to read. The last records are all that matter.
    public var tailBytes: Int

    public init(
        root: URL,
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = ClaudeCodeScanner.processExists,
        recentWindow: TimeInterval = 7 * 24 * 3600,
        tailBytes: Int = 512 * 1024
    ) {
        self.root = root
        self.isProcessAlive = isProcessAlive
        self.recentWindow = recentWindow
        self.tailBytes = tailBytes
    }

    /// Claude Code's folder for the current user, sandbox or not.
    public static func defaultRoot(home: URL? = nil) -> URL {
        (home ?? FileStore.realHomeDirectory()).appending(path: ".claude", directoryHint: .isDirectory)
    }

    public func scan(now: Date = .now) throws -> [AgentSession] {
        let registry = readRegistry()
        var sessions: [String: AgentSession] = [:]

        for (id, entry) in registry {
            sessions[id] = AgentSession(
                id: id, cwd: entry.cwd, name: entry.name, pid: entry.pid,
                startedAt: entry.startedAt, lastActivity: entry.startedAt ?? now,
                isLive: isProcessAlive(entry.pid))
        }

        for transcript in transcripts() {
            guard let modified = transcript.modified, now.timeIntervalSince(modified) <= recentWindow
            else { continue }
            let id = transcript.url.deletingPathExtension().lastPathComponent
            let tail = Self.parseTail(readTail(of: transcript.url))
            if var s = sessions[id] {
                s.lastActivity = max(s.lastActivity, modified)
                if let cwd = tail.cwd { s.cwd = Project.canonical(cwd) }
                s.lastPrompt = tail.lastPrompt ?? s.lastPrompt
                sessions[id] = s
            } else if let cwd = tail.cwd {
                sessions[id] = AgentSession(
                    id: id, cwd: cwd, lastActivity: modified, lastPrompt: tail.lastPrompt, isLive: false)
            }
        }

        return sessions.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: Registry

    struct RegistryEntry {
        var pid: Int32
        var cwd: String
        var name: String?
        var startedAt: Date?
    }

    func readRegistry() -> [String: RegistryEntry] {
        let dir = root.appending(path: "sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [:] }
        var out: [String: RegistryEntry] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let sessionID = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String
            else { continue }
            let started = (obj["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            out[sessionID] = RegistryEntry(pid: pid, cwd: cwd, name: obj["name"] as? String, startedAt: started)
        }
        return out
    }

    // MARK: Transcripts

    struct Transcript {
        var url: URL
        var modified: Date?
    }

    func transcripts() -> [Transcript] {
        let projects = root.appending(path: "projects")
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [Transcript] = []
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                out.append(Transcript(url: file, modified: modified))
            }
        }
        return out
    }

    func readTail(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Data() }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.readToEnd()) ?? Data()
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: newline)...]
        }
        return data
    }

    struct Tail: Equatable {
        var cwd: String?
        var lastPrompt: String?
    }

    /// Walks the last records of a transcript. The newest record with a `cwd` wins, since
    /// a session can move folder after it starts. The last prompt is the newest user
    /// record a person typed: not a tool result, not a hook, not a system reminder.
    static func parseTail(_ data: Data) -> Tail {
        var tail = Tail()
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if tail.cwd == nil, let cwd = obj["cwd"] as? String { tail.cwd = cwd }
            if tail.lastPrompt == nil, let prompt = humanPrompt(obj) { tail.lastPrompt = prompt }
            if tail.cwd != nil, tail.lastPrompt != nil { break }
        }
        return tail
    }

    static func humanPrompt(_ obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "user",
              obj["isMeta"] as? Bool != true,
              obj["isSidechain"] as? Bool != true,
              let message = obj["message"] as? [String: Any]
        else { return nil }
        var text: String
        if let s = message["content"] as? String {
            text = s
        } else if let parts = message["content"] as? [[String: Any]] {
            // A tool result is an agent's turn, not a person's.
            guard !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return nil
        }
        text = stripReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return firstLine(text, limit: 160)
    }

    /// Drops `<system-reminder>…</system-reminder>` blocks and their kin.
    static func stripReminders(_ text: String) -> String {
        var out = text
        for tag in ["system-reminder", "command-name", "command-message", "command-args", "local-command-stdout"] {
            while let open = out.range(of: "<\(tag)>") {
                guard let close = out.range(of: "</\(tag)>", range: open.upperBound..<out.endIndex) else {
                    out.removeSubrange(open.lowerBound..<out.endIndex)
                    break
                }
                out.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        return out
    }

    static func firstLine(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        if line.count <= limit { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Processes

    /// True when a process with that pid exists. Uses `sysctl`, which works from inside
    /// the sandbox, where signalling another process does not.
    public static let processExists: @Sendable (Int32) -> Bool = { pid in
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return rc == 0 && size > 0 && info.kp_proc.p_pid == pid
        #else
        return kill(pid, 0) == 0 || errno == EPERM
        #endif
    }
}
