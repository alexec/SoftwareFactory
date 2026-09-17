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

    /// One thing to say to an agent: the words, and whatever was dropped on it with them.
    /// A pair rather than a string, because an attachment queues with the words it came
    /// with rather than arriving in some later turn on its own. (T427.)
    struct Said {
        var words: String
        var files: [String] = []
    }

    private final class Held {
        let connection: ACPConnection
        var state: AgentDaemon.Running
        var kind: LaunchAgent
        var cwd: String
        /// What it is doing, folded as the lines go past. Bounded on purpose: the whole
        /// transcript belongs on the page reading it, not in the daemon watching sixteen.
        var headline = ACPHeadline()
        /// Things waiting for the turn in flight to finish. See `prompt(_:_:)`.
        var pending: [Said] = []
        /// The question it is blocked on, as it came off the wire, so the answer can be
        /// put back in the shape the agent asked in.
        var asked: ACP.Elicitation?
        /// The modes this agent offered, and the one it is in, so the daemon can put it
        /// back into asking or stop it asking when the person changes their mind.
        var modes: [String] = []
        var mode: String?
        /// How this agent says a person logs in, off its handshake. Read when a start
        /// fails and not before. (T435.)
        var ways: [ACP.WayIn] = []
        /// Set when a person picked this agent's mode themselves, so the floor's own
        /// setting stops moving it. One agent in auto and another asking is the ordinary
        /// case, not a conflict to resolve. (Alex, 16 Sep 2026.)
        var modeChosenByHand = false
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
        case .mode:
            return chooseMode(request)
        case .merge:
            return merge(request)
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
        // The model the person named, as a flag for the three that take one and in the
        // environment for the one whose adapter takes no arguments. (T462.)
        guard var launch = launch(kind) else { return .no("\(kind.title) does not speak ACP.") }
        // The flag goes on whatever this kind was going to be started with, rather than on
        // what it would be started with by default: a test hands in a stub that speaks ACP
        // and nothing else, and rebuilding the launch here threw the stub away.
        let wanted = (request.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty, case .flag(let flag) = kind.howToSayTheModel {
            launch = LaunchAgent.ACPLaunch(command: launch.command,
                                           arguments: launch.arguments + [flag, wanted])
        }
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
        guard store.canKeepTranscripts else {
            return .no("The daemon cannot write to \(store.root.path)/transcripts, so it could not keep a record of what this agent does. Start it from the app rather than by hand.")
        }
        let transcript = store.transcriptFile(for: agent)
        // A resume keeps the log: that is the conversation being picked back up. A fresh
        // start writes over it, because a new conversation under an old log reads as one
        // conversation that has lost its middle.
        if !resuming { try? FileManager.default.removeItem(at: transcript) }

        let connection = ACPConnection(
            agent: agent, command: binary, arguments: launch.arguments, cwd: cwd,
            environment: environment(for: cwd).merging(kind.environment(model: request.model)) { _, new in new },
            transcript: transcript,
            complaints: store.complaintsFile(for: agent))

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
                $0.waitingToSay = []
            }
            self?.guarded.sync { self?.held[agent]?.pending = [] }
        }
        connection.onLine = { [weak self] line in
            self?.guarded.sync {
                guard let one = self?.held[agent] else { return }
                one.headline.apply(line: line)
                one.state.line = one.headline.line
                // The mode it is in now, as opposed to the mode we last asked for. An
                // agent can change its own, and a set_mode can fail to take; either way
                // the menu on its page was naming the mode we wanted rather than the one
                // it is in. This is the agent saying so, not a person choosing, so
                // `modeChosenByHand` is left alone and the floor's stance still applies to
                // it. (T426.)
                if case .update(_, let update) = ACP.read(line: line) {
                    switch update {
                    case .mode(let id) where !id.isEmpty:
                        one.mode = id
                        one.state.mode = id
                    // What it can be asked to do, which arrives when the session starts
                    // and again whenever the set changes. (T436.)
                    case .commands(let listed): one.state.commands = listed
                    default: break
                    }
                }
            }
        }
        // The agent's own question. Blocked on it exactly like a permission request, and
        // never answered for it: a permission is a yes or no about a tool, and this is a
        // decision only the person has. (T373.)
        // Taken back by the agent: the question stops being asked. The escalation on the
        // floor is closed by the app, which sees `asking` go and does the same thing it
        // does when the daemon gives up on one. (T493.)
        connection.onWithdrawn = { [weak self] id in
            guard let self else { return }
            guarded.sync {
                guard let held = self.held[agent] else { return }
                guard id == nil || held.state.asking?.requestID == id else { return }
                held.state.tookBack = id ?? held.state.asking?.requestID
                held.asked = nil
                held.state.asking = nil
            }
        }
        connection.onQuestion = { [weak self] id, asked in
            guard let self else { return }
            self.guarded.sync {
                guard let held = self.held[agent] else { return }
                held.asked = asked
                held.state.tookBack = nil
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
            // What it says it will take in a prompt. Read here and kept, because it is per
            // agent and not the same twice: Grok takes no image and Cursor takes no
            // embedded resource. (T427, off the grid in T428.)
            let hello = try await connection.ask("initialize", ACP.initialize())
            let handshake = hello.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            } ?? [:]
            let takes = ACP.Attachments.read(handshake)
            // And how it says to log in, kept for the one moment it matters: a start that
            // fails. (T435.)
            let ways = ACP.WayIn.read(handshake)
            guarded.sync {
                self.held[agent]?.state.takes = takes
                self.held[agent]?.ways = ways
            }
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
                self.held[agent]?.state.modes = ACP.Modes.listed(in: answered)
                self.held[agent]?.state.mode = ACP.Modes.current(in: answered)
                // Everything else the agent says its session is set to: the model, the
                // effort, fast mode. It has been sending these all along and nothing read
                // them, so two of the four were reachable nowhere in the factory. (R69.)
                self.held[agent]?.state.options = ACP.options(in: answered)
            }
            // A mode the person picked as they started it beats the floor's setting, and
            // goes on beating it: they said what this one agent is for while they were
            // starting it, which is the same decision as picking one on its page later.
            // One it turns out not to offer is no mode at all, so the floor's setting
            // stands rather than the start failing over a menu row. (T466.)
            let picked = (request.mode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !picked.isEmpty, offered.contains(picked) {
                guarded.sync {
                    self.held[agent]?.mode = picked
                    self.held[agent]?.state.mode = picked
                    self.held[agent]?.modeChosenByHand = true
                }
                connection.tell("session/set_mode", ACP.setMode(picked, session: session))
            } else {
                setMode(agent, to: store.throttle().permissions)
            }
            if let words = request.text, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt(agent, words)
            }
            return AgentDaemon.Reply(ok: true, session: session)
        } catch {
            connection.stop()
            change(agent) { $0.state = .failed }
            // An agent that declares a way in and then will not start is almost always one
            // nobody has logged in. Saying which command to run is the whole of the fix:
            // the alternative is a failed start with nothing to do about it, and the only
            // thing that says why is a stderr file nobody opens. (T435.)
            let ways = guarded.sync { self.held[agent]?.ways ?? [] }
            return .no(ACP.whyItWouldNotStart(error.localizedDescription,
                                              kind: kind.title, ways: ways))
        }
    }

    /// The session an agent had, read back off its own transcript. The daemon keeps no
    /// second record: the log is the record, and a daemon restart must not lose the
    /// conversation the app is about to ask it to pick back up.
    private func knownSession(for agent: UUID) -> String? {
        for line in store.transcriptLines(for: agent).reversed() {
            if case .update(let session, _) = ACP.read(line: line) { return session }
        }
        return nil
    }

    // MARK: Saying things to it

    private func say(_ request: AgentDaemon.Request) -> AgentDaemon.Reply {
        guard let agent = request.agent, let one = look(agent) else { return .no("Nobody here by that name.") }
        guard one.state.state == .running else { return .no("It is not running.") }
        let files = request.files ?? []
        let words = request.text ?? ""
        guard !words.isEmpty || !files.isEmpty else { return .no("Nothing to say.") }
        prompt(agent, Said(words: words, files: files))
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
    private func prompt(_ agent: UUID, _ said: Said) {
        let queued: Bool = guarded.sync {
            guard let held = held[agent] else { return true }
            guard held.state.isPrompting else { return false }
            held.pending.append(said)
            held.state.queued = held.pending.count
            held.state.waitingToSay = held.pending.map(\.words)
            return true
        }
        if queued { return }
        say(agent, said)
    }

    /// Everything else in here says words and nothing else.
    private func prompt(_ agent: UUID, _ words: String) {
        prompt(agent, Said(words: words))
    }

    /// Everything waiting, joined into one thing to say.
    ///
    /// The queue exists because nothing is said to an agent mid-turn, and it sends one at a
    /// time because two things said are two things said. But a person who has thought of
    /// four more instructions while an agent works did not mean four turns: they meant the
    /// next turn to have all four in it, and one at a time makes the agent do the first and
    /// then be interrupted by the second, which is the shape this queue exists to avoid.
    /// So this is offered rather than done: the queue stays one-at-a-time and the person
    /// says when a run of them is really one instruction.
    ///
    /// Blank lines between them, because they were typed as separate thoughts and reading
    /// them as one paragraph would join the end of one sentence to the start of another.
    /// Files come along in the order their words did. (Alex, 16 Sep 2026, T541.)
    func merge(_ request: AgentDaemon.Request) -> AgentDaemon.Reply {
        guard let agent = request.agent else { return .no("A merge has to say which agent.") }
        guard look(agent) != nil else { return .no("Nobody here by that name.") }
        return guarded.sync {
            guard let held = held[agent] else { return .no("Nobody here by that name.") }
            guard held.pending.count > 1 else { return .no("There is nothing to merge.") }
            let words = held.pending.map(\.words)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            let files = held.pending.flatMap(\.files)
            held.pending = [Said(words: words, files: files)]
            held.state.queued = 1
            held.state.waitingToSay = [words]
            return .yes
        }
    }

    /// The next thing waiting, once a turn has finished. One at a time: they are separate
    /// things to say and each gets its own turn.
    private func sayNext(_ agent: UUID) {
        let next: Said? = guarded.sync {
            guard let held = held[agent], !held.pending.isEmpty else { return nil }
            let said = held.pending.removeFirst()
            held.state.queued = held.pending.count
            held.state.waitingToSay = held.pending.map(\.words)
            return said
        }
        guard let next else { return }
        say(agent, next)
    }

    private func say(_ agent: UUID, _ said: Said) {
        guard let one = look(agent), let session = one.state.session else { return }
        let words = said.words
        // What was dropped on it, in the shape this agent takes. Reading happens here
        // rather than in the app because this is the side that knows what it will take,
        // and a screenshot down a unix socket as base64 is a megabyte of nothing. (T427.)
        let blocks = said.files.compactMap { path -> [String: Any]? in
            guard let attachment = Self.attachment(at: path) else { return nil }
            return ACP.block(for: attachment, takes: one.state.takes).block
        }
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
            _ = try? await one.connection.ask(
                "session/prompt", ACP.prompt(words, attaching: blocks, session: session), patience: nil)
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

    /// The person picked this agent's mode themselves. It stops following the floor's
    /// setting from here: one agent in auto and another asking is the ordinary case.
    private func chooseMode(_ request: AgentDaemon.Request) -> AgentDaemon.Reply {
        guard let agent = request.agent, let one = look(agent) else { return .no("Nobody here by that name.") }
        guard let wanted = request.optionID else { return .no("Which mode?") }
        guard one.state.modes.contains(where: { $0.id == wanted }) else {
            return .no("\(wanted) is not one of its modes.")
        }
        guard let session = one.state.session else { return .no("It has no session.") }
        guarded.sync {
            held[agent]?.mode = wanted
            held[agent]?.state.mode = wanted
            held[agent]?.modeChosenByHand = true
        }
        one.connection.tell("session/set_mode", ACP.setMode(wanted, session: session))
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
            held.state.mode = wanted
            return (wanted, held.connection, session)
        }
        guard let (wanted, connection, session) = want else { return }
        connection.tell("session/set_mode", ACP.setMode(wanted, session: session))
    }

    /// The person changed their mind in Settings, so every agent that has a mode goes
    /// into the one that matches. Called off `list`, which the app runs on its refresh.
    private func followTheStance() {
        let stance = store.throttle().permissions
        for one in everythingHeld() where one.state.state == .running && !one.modeChosenByHand {
            setMode(one.state.agent, to: stance)
        }
    }

    /// Two things nobody has answered, and the same clock over both, because in both cases
    /// the agent is doing nothing at all until it hears back: one raised at half past five
    /// and not seen is an agent that did nothing all evening. (T373.)
    ///
    /// They end differently, and the difference is the whole of it.
    ///
    /// **A permission request** is answered with the recommended option, which is always
    /// allow once and never allow always. The agent asked whether it may do the thing it
    /// was already doing, the fallback is the agent's own, and it is undone by stopping it.
    ///
    /// **The agent's own question** is declined rather than answered. There is no
    /// recommendation to take: measured on every elicitation in this store's transcripts,
    /// not one carries a recommended option, and Claude Code declares `recommendedValue`
    /// in its handshake capabilities and sends it on permission requests rather than on
    /// forms. Taking one anyway would mean picking whichever option the agent happened to
    /// list first and writing it down as a decision Alex made, and the one thing this
    /// factory has always refused is making the choice for the person. So the agent is
    /// told nobody answered and is freed to get on with something else, and the question
    /// stays open on the Needs you strip, on the phone and on the Lock Screen until
    /// somebody answers it. That is the same shape as raising one and carrying on.
    /// (T421, off A74's audit.)
    private func answerLateQuestions(now: Date = .now) {
        for one in everythingHeld() {
            for late in AgentDaemon.late(in: one.state, now: now) {
                switch late {
                case .allow(let requestID, let optionID):
                    one.connection.answerPermission(
                        id: requestID, with: ACP.permissionAnswer(optionID: optionID))
                    change(one.state.agent) { $0.waiting = nil }
                case .decline(let requestID):
                    one.connection.answerPermission(
                        id: requestID, with: ACP.Elicitation.declined)
                    change(one.state.agent) { $0.asking = nil }
                    guarded.sync { held[one.state.agent]?.asked = nil }
                }
            }
        }
    }

    /// A file on disk as something to send. An image by its type, anything readable as
    /// words, and nothing at all for a binary nobody can do anything with: sending its
    /// name would be pretending. (T427.)
    public static func attachment(at path: String) -> ACP.Attachment? {
        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        let images = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                      "gif": "image/gif", "webp": "image/webp", "heic": "image/heic"]
        if let type = images[ext] {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return .image(data: data, mimeType: type, name: name)
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return .words(path: path, text: text, name: name)
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
