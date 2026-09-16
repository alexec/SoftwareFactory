#if os(macOS)
import Foundation

/// The daemon. It holds every ACP agent's process and answers the app's questions about
/// them, and it is the whole reason this floor can run on ACP at all: an ACP agent dies
/// with its client, the app is rebuilt a dozen times a day, so the app is not the client.
///
/// What it deliberately is not: a terminal multiplexer. No pty, no ANSI, no scrollback,
/// no resize. It spawns a process, keeps a pipe, appends what comes out of it to a file,
/// and hands on the two questions an agent asks of a person. (T373.)
public final class AgentFloor: @unchecked Sendable {
    private let store: FileStore
    private let guarded = DispatchQueue(label: "software-factory.floor.state")
    private var held: [UUID: Held] = [:]
    /// Where the binaries are. The daemon is started by the app, which inherits no login
    /// shell, so the path it would get is the bare one.
    private let searchPaths: [String]

    /// What to run for a given kind. The default is the kind's own answer; a test hands
    /// in a stub that speaks ACP and nothing else, which is how everything below the
    /// socket is tested without a model in the loop.
    private let launch: @Sendable (LaunchAgent) -> LaunchAgent.ACPLaunch?

    public init(store: FileStore, searchPaths: [String] = AgentFloor.defaultSearchPaths,
                launch: @escaping @Sendable (LaunchAgent) -> LaunchAgent.ACPLaunch? = { $0.acp }) {
        self.store = store
        self.searchPaths = searchPaths
        self.launch = launch
    }

    public static let defaultSearchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.bun/bin",
    ]

    private final class Held {
        let connection: ACPConnection
        var state: AgentDaemon.Running
        var kind: LaunchAgent
        var cwd: String
        /// What it is doing, folded as the lines go past. Bounded on purpose: the whole
        /// transcript belongs on the page reading it, not in the daemon watching sixteen.
        var headline = ACPHeadline()
        /// Words waiting for the turn in flight to finish. See `prompt(_:_:)`.
        var pending: [String] = []
        /// The question it is blocked on, as it came off the wire, so the answer can be
        /// put back in the shape the agent asked in.
        var asked: ACP.Elicitation?
        /// The modes this agent offered, and the one it is in, so the daemon can put it
        /// back into asking or stop it asking when the person changes their mind.
        var modes: [String] = []
        var mode: String?
        init(connection: ACPConnection, state: AgentDaemon.Running, kind: LaunchAgent, cwd: String) {
            self.connection = connection
            self.state = state
            self.kind = kind
            self.cwd = cwd
        }
    }

    // MARK: What the app asks

    public func handle(_ request: AgentDaemon.Request) async -> AgentDaemon.Reply {
        switch request.op {
        case .ping:
            return AgentDaemon.Reply(ok: true, pid: ProcessInfo.processInfo.processIdentifier)
        case .list:
            answerLateQuestions()
            followTheStance()
            return AgentDaemon.Reply(ok: true, agents: everything(), pid: ProcessInfo.processInfo.processIdentifier)
        case .start, .resume:
            return await start(request, resuming: request.op == .resume)
        case .say:
            return say(request)
        case .cancel:
            guard let agent = request.agent, let one = look(agent) else { return .no("Nobody here by that name.") }
            guard let session = one.state.session else { return .no("It has no session to stop.") }
            one.connection.tell("session/cancel", ACP.cancel(session: session))
            return .yes
        case .stop:
            guard let agent = request.agent, let one = look(agent) else { return .no("Nobody here by that name.") }
            one.connection.stop()
            return .yes
        case .permission:
            return answer(request)
        case .answer:
            return answerQuestion(request)
        case .shutdown:
            for one in everythingHeld() { one.connection.stop() }
            return .yes
        }
    }

    // MARK: Starting

    private func start(_ request: AgentDaemon.Request, resuming: Bool) async -> AgentDaemon.Reply {
        guard let agent = request.agent else { return .no("A start has to say which agent.") }
        guard let cwd = request.cwd, !cwd.isEmpty else { return .no("An agent has to stand somewhere.") }
        guard FileManager.default.fileExists(atPath: cwd) else { return .no("There is no folder at \(cwd).") }
        let kind = LaunchAgent.remembered(request.kind)
        guard let launch = launch(kind) else { return .no("\(kind.title) does not speak ACP.") }
        guard let binary = find(launch.command) else {
            let install = kind.acpInstall.map { " Install it with: \($0)" } ?? ""
            return .no("\(launch.command) is not on this Mac.\(install)")
        }

        // One agent, one process. Starting one that is already here would leave the old
        // one running with nothing pointing at it.
        if let existing = look(agent), existing.connection.isRunning {
            return .no("\(agent.uuidString) is already running.")
        }

        // Checked before anything is spawned. A daemon that cannot write here still
        // starts the agent and still talks to it, and every page is empty for ever: the
        // transcript is the record, and a silent failure to keep it is the worst one
        // available. It happens for real, because the store is a group container and a
        // process started outside the app may not be allowed in. (T373.)
        guard AgentDaemon.canKeepTranscripts(in: store) else {
            return .no("The daemon cannot write to \(store.root.path)/transcripts, so it could not keep a record of what this agent does. Start it from the app rather than by hand.")
        }
        let transcript = AgentDaemon.transcriptFile(for: agent, in: store)
        // A resume keeps the log: that is the conversation being picked back up. A fresh
        // start writes over it, because a new conversation under an old log reads as one
        // conversation that has lost its middle.
        if !resuming { try? FileManager.default.removeItem(at: transcript) }

        let connection = ACPConnection(
            agent: agent, command: binary, arguments: launch.arguments, cwd: cwd,
            environment: environment(for: cwd), transcript: transcript,
            complaints: AgentDaemon.complaintsFile(for: agent, in: store))

        let held = Held(connection: connection,
                        state: AgentDaemon.Running(agent: agent, state: .starting),
                        kind: kind, cwd: cwd)
        connection.onExit = { [weak self] status in
            self?.change(agent) {
                $0.state = $0.session == nil ? .failed : .stopped
                $0.exit = status
                $0.pid = nil
                $0.waiting = nil
                $0.asking = nil
                $0.isPrompting = false
                $0.queued = 0
            }
            self?.guarded.sync { self?.held[agent]?.pending = [] }
        }
        connection.onLine = { [weak self] line in
            self?.guarded.sync {
                guard let one = self?.held[agent] else { return }
                one.headline.apply(line: line)
                one.state.line = one.headline.line
            }
        }
        // The agent's own question. Blocked on it exactly like a permission request, and
        // never answered for it: a permission is a yes or no about a tool, and this is a
        // decision only the person has. (T373.)
        connection.onQuestion = { [weak self] id, asked in
            guard let self else { return }
            self.guarded.sync {
                guard let held = self.held[agent] else { return }
                held.asked = asked
                held.state.asking = AgentDaemon.Question(
                    requestID: id,
                    question: asked.message.isEmpty ? (asked.about ?? "It wants your answer.") : asked.message,
                    options: asked.options.map {
                        AgentDaemon.Question.Option(value: $0.value, title: $0.title, detail: $0.detail)
                    },
                    takesWords: asked.customField != nil)
            }
        }
        connection.onPermission = { [weak self] id, ask in
            guard let self else { return }
            // Read fresh each time, so changing it in Settings takes effect on the next
            // question rather than on the next restart of the daemon.
            let stance = self.store.throttle().permissions
            if stance.allows(ask.toolCall.kind) {
                // Always, not once. The person has already decided in advance, so the
                // answer is a standing one and the agent stops asking about this kind of
                // thing: one round trip rather than one per call. The once-only preference
                // belongs to the other path, where nobody answered and no decision was
                // made on purpose. (Alex, 16 Sep 2026.)
                let yes = ask.options.first { $0.kind == .allowAlways } ?? ask.recommended
                if let yes {
                    connection.answerPermission(id: id, with: ACP.permissionAnswer(optionID: yes.optionID))
                    return
                }
            }
            self.change(agent) {
                $0.waiting = AgentDaemon.Pending(
                    requestID: id, title: ask.toolCall.heading,
                    kind: ask.toolCall.kind?.rawValue, options: ask.options)
            }
        }
        put(agent, held)

        do {
            try connection.start()
            _ = try await connection.ask("initialize", ACP.initialize())
            let servers = [ACP.factoryServer(agent: agent)]
            var answered: [String: Any] = [:]
            let session: String
            if resuming, let known = knownSession(for: agent) {
                let back = try await connection.ask("session/load", ACP.loadSession(known, cwd: cwd, mcpServers: servers),
                                                    patience: 120)
                answered = back.flatMap {
                    (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                } ?? [:]
                session = known
            } else {
                let answer = try await connection.ask("session/new", ACP.newSession(cwd: cwd, mcpServers: servers),
                                                      patience: 120)
                guard let data = answer,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let made = body["sessionId"] as? String
                else { throw ACPConnection.Failure.notStarted("it made no session") }
                session = made
                answered = body
            }
            let offered = ACP.Modes.offered(in: answered)
            change(agent) {
                $0.state = .running
                $0.session = session
                $0.pid = connection.pid
            }
            // Into the mode that matches what the person said an agent may do. Where an
            // agent has one, this beats answering every request instantly: it stops
            // asking at all. (T373.)
            guarded.sync {
                self.held[agent]?.modes = offered
                self.held[agent]?.mode = ACP.Modes.current(in: answered)
            }
            setMode(agent, to: store.throttle().permissions)
            if let words = request.text, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt(agent, words)
            }
            return AgentDaemon.Reply(ok: true, session: session)
        } catch {
            connection.stop()
            change(agent) { $0.state = .failed }
            return .no(error.localizedDescription)
        }
    }

    /// The session an agent had, read back off its own transcript. The daemon keeps no
    /// second record: the log is the record, and a daemon restart must not lose the
    /// conversation the app is about to ask it to pick back up.
    private func knownSession(for agent: UUID) -> String? {
        for line in AgentDaemon.transcriptLines(for: agent, in: store).reversed() {
            if case .update(let session, _) = ACP.read(line: line) { return session }
        }
        return nil
    }

    // MARK: Saying things to it

    private func say(_ request: AgentDaemon.Request) -> AgentDaemon.Reply {
        guard let agent = request.agent, let one = look(agent) else { return .no("Nobody here by that name.") }
        guard one.state.state == .running else { return .no("It is not running.") }
        guard let words = request.text, !words.isEmpty else { return .no("Nothing to say.") }
        prompt(agent, words)
        return .yes
    }

    /// A turn, started and not waited for. Everything the factory says to an agent comes
    /// through here: the words it starts with, a nudge, a message from another agent, the
    /// status report ask. One path, the same as the typed line was.
    ///
    /// **Nothing is said to an agent in the middle of a turn.** The four do three
    /// different things with a prompt that arrives while they are working, and two of them
    /// lose something: Claude Code queues it and answers both, Copilot drops it without a
    /// word, and Cursor cancels the turn in flight to take the new one. Measured, not read
    /// (T373). So the daemon queues instead, and every agent behaves the way the best of
    /// them does. It is also what the terminal did: a message was delivered only when
    /// something took it.
    private func prompt(_ agent: UUID, _ words: String) {
        let queued: Bool = guarded.sync {
            guard let held = held[agent] else { return true }
            guard held.state.isPrompting else { return false }
            held.pending.append(words)
            held.state.queued = held.pending.count
            return true
        }
        if queued { return }
        say(agent, words)
    }

    /// The next thing waiting, once a turn has finished. One at a time: they are separate
    /// things to say and each gets its own turn.
    private func sayNext(_ agent: UUID) {
        let next: String? = guarded.sync {
            guard let held = held[agent], !held.pending.isEmpty else { return nil }
            let words = held.pending.removeFirst()
            held.state.queued = held.pending.count
            return words
        }
        guard let next else { return }
        say(agent, next)
    }

    private func say(_ agent: UUID, _ words: String) {
        guard let one = look(agent), let session = one.state.session else { return }
        // Written into the log ourselves, because the agent does not echo what it was
        // told except on a replay, and a page showing only the answers is a page of an
        // agent talking to itself.
        one.connection.writeDown(["jsonrpc": "2.0", "method": "session/update", "params": [
            "sessionId": session,
            "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": words]],
        ]])
        guarded.sync {
            guard let held = held[agent] else { return }
            held.headline.apply(.userMessage(.text(words)))
            held.state.line = held.headline.line
        }
        change(agent) { $0.isPrompting = true }
        Task { [weak self] in
            // No patience: a turn takes as long as it takes, and the way to stop waiting
            // on one is to cancel it.
            _ = try? await one.connection.ask("session/prompt", ACP.prompt(words, session: session), patience: nil)
            self?.change(agent) { $0.isPrompting = false }
            // And whatever came in while it was working goes now.
            self?.sayNext(agent)
        }
    }

    // MARK: Permission

    private func answer(_ request: AgentDaemon.Request) -> AgentDaemon.Reply {
        guard let agent = request.agent, let one = look(agent) else { return .no("Nobody here by that name.") }
        guard let waiting = one.state.waiting else { return .no("It is not waiting on anything.") }
        guard request.requestID == nil || request.requestID == waiting.requestID else {
            return .no("It has moved on from that question.")
        }
        let option = request.optionID ?? waiting.fallback?.optionID
        guard let option else { return .no("That question has no options, which should not happen.") }
        one.connection.answerPermission(id: waiting.requestID, with: ACP.permissionAnswer(optionID: option))
        change(agent) { $0.waiting = nil }
        return .yes
    }

    /// The person answered the agent's own question.
    private func answerQuestion(_ request: AgentDaemon.Request) -> AgentDaemon.Reply {
        guard let agent = request.agent, let one = look(agent) else { return .no("Nobody here by that name.") }
        guard let waiting = one.state.asking, let asked = one.asked else {
            return .no("It is not asking anything.")
        }
        guard request.requestID == nil || request.requestID == waiting.requestID else {
            return .no("It has moved on from that question.")
        }
        one.connection.answerPermission(
            id: waiting.requestID,
            with: asked.answer(option: request.optionID, words: request.words ?? ""))
        guarded.sync {
            held[agent]?.state.asking = nil
            held[agent]?.asked = nil
        }
        return .yes
    }

    /// Puts an agent into the mode that matches what the person said agents may do, when
    /// it has one to go into. Nothing happens for an agent with no modes, and for those
    /// the factory answers their requests instead.
    private func setMode(_ agent: UUID, to permissions: Throttle.Permissions) {
        let want: (String, ACPConnection, String)? = guarded.sync {
            guard let held = held[agent], let session = held.state.session,
                  let wanted = ACP.Modes.wanted(permissions, from: held.modes),
                  wanted != held.mode
            else { return nil }
            held.mode = wanted
            return (wanted, held.connection, session)
        }
        guard let (wanted, connection, session) = want else { return }
        connection.tell("session/set_mode", ACP.setMode(wanted, session: session))
    }

    /// The person changed their mind in Settings, so every agent that has a mode goes
    /// into the one that matches. Called off `list`, which the app runs on its refresh.
    private func followTheStance() {
        let stance = store.throttle().permissions
        for one in everythingHeld() where one.state.state == .running {
            setMode(one.state.agent, to: stance)
        }
    }

    /// A permission request nobody has answered inside the hour gets the recommended
    /// option and a line in the transcript saying the factory took it.
    ///
    /// There has to be something here. This is not a question sitting in a list: the
    /// agent is blocked on it, so one raised at half past five and not seen is an agent
    /// that did nothing all evening. (T373.)
    private func answerLateQuestions(now: Date = .now) {
        for one in everythingHeld() {
            guard let waiting = one.state.waiting,
                  now.timeIntervalSince(waiting.asked) > AgentDaemon.answerWithin,
                  let option = waiting.fallback
            else { continue }
            one.connection.answerPermission(id: waiting.requestID,
                                            with: ACP.permissionAnswer(optionID: option.optionID))
            change(one.state.agent) { $0.waiting = nil }
        }
    }

    // MARK: Odds and ends

    /// The agent's own environment, which is the whole point of the daemon not being
    /// sandboxed: ~/.claude, the keychain, git, node and Xcode are all here.
    private func environment(for cwd: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        let missing = searchPaths.filter { !path.split(separator: ":").contains(Substring($0)) }
        if !missing.isEmpty { environment["PATH"] = (missing + [path]).joined(separator: ":") }
        environment["PWD"] = cwd
        return environment
    }

    private func find(_ command: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        return searchPaths.lazy.map { "\($0)/\(command)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func look(_ agent: UUID) -> Held? { guarded.sync { held[agent] } }
    private func put(_ agent: UUID, _ one: Held) { guarded.sync { held[agent] = one } }
    private func everythingHeld() -> [Held] { guarded.sync { Array(held.values) } }
    public func everything() -> [AgentDaemon.Running] {
        guarded.sync { held.values.map(\.state) }.sorted { $0.startedAt < $1.startedAt }
    }

    private func change(_ agent: UUID, _ edit: @escaping (inout AgentDaemon.Running) -> Void) {
        guarded.sync {
            guard let one = held[agent] else { return }
            edit(&one.state)
        }
    }
}
#endif
