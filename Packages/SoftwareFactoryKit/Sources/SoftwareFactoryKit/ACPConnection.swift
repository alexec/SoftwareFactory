#if os(macOS)
import Foundation

/// One agent, as a process with JSON going along a pipe. The daemon owns these; nothing
/// in the app ever holds one.
///
/// Deliberately not an actor. Every line an agent sends is appended to its transcript in
/// the order it arrived, and actor hops are not ordered: `Task { await self.took(line) }`
/// from a pipe callback reorders a conversation under load. So the reading, the line
/// buffering and the appending all happen on the pipe's own serial queue, in order, by
/// construction, and a lock guards the small amount of state that two threads touch.
/// (T373.)
public final class ACPConnection: @unchecked Sendable {
    /// The requests we are waiting on answers to. Its own small class because a
    /// continuation is not `Sendable` and every ergonomic locking helper in the standard
    /// library wants a `sending` closure, which one cannot cross. Plain methods, a plain
    /// lock, and the awkwardness lives in one place.
    private final class Waiters: @unchecked Sendable {
        private var map: [Int: CheckedContinuation<Data?, Error>] = [:]
        private let lock = NSLock()

        /// Answers false, having failed the continuation itself, when the agent has
        /// already gone: the caller must not then write to a dead pipe.
        func add(_ id: Int, _ continuation: CheckedContinuation<Data?, Error>,
                 unlessClosed closed: () -> Bool) -> Bool {
            lock.lock()
            if closed() {
                lock.unlock()
                continuation.resume(throwing: Failure.gone)
                return false
            }
            map[id] = continuation
            lock.unlock()
            return true
        }

        func take(_ id: Int) -> CheckedContinuation<Data?, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return map.removeValue(forKey: id)
        }

        func giveUpOnEverything(_ error: Error) {
            lock.lock()
            let all = Array(map.values)
            map = [:]
            lock.unlock()
            for continuation in all { continuation.resume(throwing: error) }
        }
    }

    public let agent: UUID
    private let process = Process()
    private let toAgent = Pipe()
    private let fromAgent = Pipe()
    private let errors = Pipe()
    /// Whatever the agent writes to stderr, kept beside its transcript. It has to be
    /// drained anyway or the pipe fills and the child blocks, which looks exactly like an
    /// agent that has stopped thinking. Keeping it costs nothing and is the only thing
    /// that says why an agent would not start.
    private let grumbles: FileHandle?
    private let log: FileHandle?
    /// Everything written to the transcript goes through here, in submission order.
    ///
    /// One handle, because two handles on one file each keep their own offset: the
    /// daemon opened a second one to write down what the factory said, seeked to the
    /// end, wrote, and the connection's next line landed back at its own older offset
    /// and wiped it. The prompts simply were not in the log. (T373.)
    private let logQueue = DispatchQueue(label: "software-factory.acp.log")

    /// A serial queue rather than a lock, and the critical sections are microseconds
    /// long. `NSLock.withLock` takes a `sending` closure, which a continuation cannot
    /// cross; this keeps the same guarantee without the dance.
    private let guarded = DispatchQueue(label: "software-factory.acp.state")
    private var nextID = 1
    private let waiting = Waiters()
    private var buffer = Data()
    private var closed = false

    /// The agent is blocked on this until it is answered. The daemon puts it in front of
    /// a person.
    public var onPermission: (@Sendable (Int, ACP.PermissionRequest) -> Void)?
    /// The agent asking the person a question. Blocked on it the same way, and put in
    /// front of a person the same way. (T373.)
    public var onQuestion: (@Sendable (Int, ACP.Elicitation) -> Void)?
    /// The agent has taken its question back, `elicitation/complete`. (T493.)
    public var onWithdrawn: (@Sendable (Int?) -> Void)?
    /// The child has gone.
    public var onExit: (@Sendable (Int32) -> Void)?
    /// Every line, after it has been written down. The daemon keeps the last one so its
    /// `list` can say what the agent is up to without reading the whole file back.
    public var onLine: (@Sendable (String) -> Void)?

    public enum Failure: LocalizedError {
        case notStarted(String)
        case gone
        case refused(code: Int, message: String)
        case tookTooLong(String)

        public var errorDescription: String? {
            switch self {
            case .notStarted(let why): "The agent would not start: \(why)"
            case .gone: "The agent has gone."
            case .refused(_, let message): message
            case .tookTooLong(let what): "The agent did not answer \(what)."
            }
        }
    }

    /// `transcript` is where every line is written down, in order, as it arrives.
    /// Writing to an agent that has just gone raises SIGPIPE, and the default for SIGPIPE
    /// is to kill the process doing the writing. That is the daemon, or whatever else is
    /// holding a connection, dying because a child exited half a millisecond earlier.
    /// Turned off once, here, rather than left to every host to remember: a type that
    /// writes to pipes owns this. The write then fails with EPIPE and is dropped, which
    /// is the right answer for a pipe whose other end has gone. (T373.)
    private static let brokenPipesAreNotFatal: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    public init(agent: UUID, command: String, arguments: [String], cwd: String,
                environment: [String: String], transcript: URL, complaints: URL? = nil) {
        _ = Self.brokenPipesAreNotFatal
        self.agent = agent
        // Created only when it is not there. `createFile` truncates, and a resume opens
        // the log of the conversation it is picking back up: making one would throw away
        // the half the person came to read. (T373.)
        if !FileManager.default.fileExists(atPath: transcript.path) {
            FileManager.default.createFile(atPath: transcript.path, contents: nil)
        }
        log = try? FileHandle(forWritingTo: transcript)
        _ = try? log?.seekToEnd()
        if let complaints {
            if !FileManager.default.fileExists(atPath: complaints.path) {
                FileManager.default.createFile(atPath: complaints.path, contents: nil)
            }
            grumbles = try? FileHandle(forWritingTo: complaints)
            _ = try? grumbles?.seekToEnd()
        } else {
            grumbles = nil
        }

        process.executableURL = URL(filePath: command)
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: cwd)
        process.environment = environment
        process.standardInput = toAgent
        process.standardOutput = fromAgent
        process.standardError = errors
    }

    public var pid: Int32? { process.isRunning ? process.processIdentifier : nil }
    public var isRunning: Bool { process.isRunning }

    // MARK: Starting and stopping

    public func start() throws {
        fromAgent.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle.availableData)
        }
        // Drained and thrown away on purpose, but drained: a pipe nobody reads fills up
        // and then the child blocks writing to it, which looks exactly like an agent
        // that has stopped thinking.
        errors.fileHandleForReading.readabilityHandler = { [grumbles] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            try? grumbles?.write(contentsOf: data)
        }
        process.terminationHandler = { [weak self] finished in
            self?.ended(finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw Failure.notStarted(error.localizedDescription)
        }
    }

    /// SIGTERM, then SIGKILL for one that ignored it, the same way an agent has always
    /// been stopped. The transcript stays on disk: what it last said is still readable,
    /// which is what leaving the tmux pane did.
    public func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let child = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func ended(_ status: Int32) {
        let first: Bool = guarded.sync {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard first else { return }
        // Anything still waiting is told, rather than left holding a task for ever.
        waiting.giveUpOnEverything(Failure.gone)
        fromAgent.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        // Behind whatever is still queued, so the last thing it said is in the file.
        logQueue.async { [log, grumbles] in
            try? log?.close()
            try? grumbles?.close()
        }
        onExit?(status)
    }

    // MARK: Reading

    /// On the pipe's serial queue, so lines are written down in the order they arrived.
    private func read(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer = buffer[buffer.index(after: end)...]
            guard !line.isEmpty else { continue }
            took(String(decoding: line, as: UTF8.self), raw: Data(line))
        }
    }

    private func took(_ line: String, raw: Data) {
        // Written down before it is acted on, so the log is the whole truth even for a
        // line that then makes something throw.
        writeDown(raw)
        onLine?(line)
        switch ACP.read(line: line) {
        case .response(let id, let result, let error):
            let continuation = waiting.take(id)
            if let error {
                continuation?.resume(throwing: Failure.refused(code: error.code, message: error.message))
            } else {
                continuation?.resume(returning: result)
            }
        case .permission(let id, let ask):
            onPermission?(id, ask)
        case .question(let id, let asked):
            onQuestion?(id, asked)
        case .withdrawn(let id):
            onWithdrawn?(id)
        case .request(let id, let method):
            // A method we have not written. Answered rather than left hanging, because an
            // agent waiting on a client that will never reply is an agent that has stopped
            // and it is not its fault; answered with an error rather than an empty success,
            // because an empty success to fs/read_text_file says "here is the file" and
            // hands over nothing, and the agent carries on with what it thinks it read.
            // -32601 is the protocol's own word for it and it names the method.
            //
            // Worth seeing when it happens: we declare no filesystem and no terminal, so a
            // call for one of those is an agent ignoring what we said we can do, and it
            // goes to the complaints file where the reason a start failed already goes.
            // (T491.)
            try? grumbles?.write(contentsOf: Data("Refused \(method): this client does not answer it.\n".utf8))
            write(["jsonrpc": "2.0", "id": id,
                   "error": ["code": -32601, "message": "Method not found: \(method)"]])
        case .update, .notification, .unrecognised:
            break
        }
    }

    // MARK: Writing

    /// A request, and the answer to it. `patience` is nil for `session/prompt`, which
    /// legitimately runs for many minutes: a turn ends when it ends, and the way to stop
    /// waiting is `session/cancel`.
    @discardableResult
    public func ask(_ method: String, _ params: [String: Any], patience: TimeInterval? = 60) async throws -> Data? {
        let id: Int? = guarded.sync {
            guard !closed else { return nil }
            defer { nextID += 1 }
            return nextID
        }
        guard let id else { throw Failure.gone }
        // Serialised here rather than inside the continuation. `[String: Any]` is not
        // Sendable, and a continuation closure may not capture one; bytes may cross.
        let message = Self.serialised(["jsonrpc": "2.0", "id": id, "method": method, "params": params])

        let answer = Task { () -> Data? in
            try await withCheckedThrowingContinuation { continuation in
                // A plain method call rather than a closure: every ergonomic locking
                // helper takes a `sending` closure, and a continuation cannot cross one.
                guard waiting.add(id, continuation, unlessClosed: { guarded.sync { closed } }) else { return }
                send(message)
            }
        }

        guard let patience else { return try await answer.value }
        // A request that never gets an answer would otherwise hold a task for ever.
        // `session/prompt` passes nil here: a turn takes as long as it takes, and the
        // way to stop waiting on one is to cancel it.
        let giveUp = Task {
            try await Task.sleep(for: .seconds(patience))
            waiting.take(id)?.resume(throwing: Failure.tookTooLong(method))
        }
        defer { giveUp.cancel() }
        return try await answer.value
    }

    /// A notification: nothing comes back, so nothing waits.
    public func tell(_ method: String, _ params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ message: [String: Any]) {
        send(Self.serialised(message))
    }

    static func serialised(_ message: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? Data()
    }

    private func send(_ data: Data) {
        guard !data.isEmpty else { return }
        // Nothing to write to. Not an error worth reporting: an agent that has gone is
        // already reported as gone, by its exit.
        guard process.isRunning else { return }
        // Off the caller's thread: a child that is not reading its stdin would otherwise
        // block whoever asked, which in the daemon is the socket answering the app.
        let handle = toAgent.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    /// A line of the factory's own into this agent's transcript, through the one handle
    /// that writes it. The agent does not echo what it was told except on a replay, so
    /// without this the page is an agent answering questions nobody asked.
    public func writeDown(_ raw: Data) {
        logQueue.async { [log] in
            try? log?.write(contentsOf: raw + Data("\n".utf8))
        }
    }

    public func writeDown(_ message: [String: Any]) {
        writeDown(Self.serialised(message))
    }

    /// Our answer to a permission request. The agent has been sitting on this.
    public func answerPermission(id: Int, with result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
#endif
