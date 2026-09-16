import Foundation
import Observation
import SoftwareFactoryKit

/// Owns the store and everything built from it. Every rule lives in SoftwareFactoryKit; this is
/// the plumbing that keeps the window current.
@Observable
@MainActor
final class AppModel {
    private(set) var snapshot = Snapshot()
    private(set) var dashboard = Dashboard.empty
    /// Every message sent to each agent, newest last. Kept beside the snapshot because
    /// messages are per recipient and never travel in it.
    private(set) var messagesByAgent: [UUID: [AgentMessage]] = [:]
    private(set) var lastRefresh: Date?
    private(set) var storeError: String?
    /// The last write that did not happen, in the person's words, until they have seen
    /// it or another write goes through. Kept apart from `storeError`, which is about
    /// reading: `persist` writes, then refreshes, and the refresh set `storeError` back
    /// to nil a line later, so a failed edit or delete said nothing anywhere and the row
    /// simply redrew as it was. (T264, Alex, 15 Sep 2026.)
    private(set) var writeError: String?
    /// Agents the daemon says have a turn in flight, refreshed on the floor's own poll.
    private(set) var busyAgents: Set<UUID> = []

    let store: FileStore?
    private(set) var serverState = "Starting"
    private(set) var machine: MachineReading?
    private(set) var throttle = Throttle.default
    @ObservationIgnored private var server: FactoryServer?
    let cloud = CloudSync()
    let notifier = Notifier()
    let dictation = Dictation()
    private(set) var isAtTheMac = true
    @ObservationIgnored private var lastCloudPull: Date?
    static let pullDecisionsEvery: TimeInterval = 15

    var hasSeenIntro: Bool {
        didSet { UserDefaults.standard.set(hasSeenIntro, forKey: Self.introKey) }
    }

    static let introKey = "hasSeenIntro"
    static let refreshEvery: Duration = .seconds(2)

    @ObservationIgnored private var ticker: _Concurrency.Task<Void, Never>?

    init() {
        hasSeenIntro = UserDefaults.standard.bool(forKey: Self.introKey)
        do {
            store = try FileStore(root: Self.storeRoot())
        } catch {
            store = nil
            storeError = error.localizedDescription
        }
        clearConnections()
        // Which process the factory is, written down before anything else can want it:
        // an agent that has just rebuilt has to stop this one, and the only way to
        // address it from a terminal is by its pid. (T271.)
        if let store, let me = FactoryProcess.current() { try? store.save(me) }
        start()
        if let store {
            let server = FactoryServer(router: HTTPRouter(server: MCPServer(store: store)), port: Self.port) { state in
                _Concurrency.Task { @MainActor [weak self] in self?.serverState = state }
            }
            server.start()
            self.server = server
        }
        _Concurrency.Task { await cloud.prepare() }
        _Concurrency.Task { await notifier.refreshStanding() }
        notifier.onDecision = { [weak self] escalationID, optionID in
            guard let self, let e = snapshot.escalations.first(where: { $0.id == escalationID }),
                  let option = e.options.first(where: { $0.id == optionID }) else { return }
            decide(e, option, by: "alex, banner")
        }
    }

    /// The app group container when the sandbox gives us one, the plain path otherwise
    /// (the same folder, reached without the sandbox's help).
    static func storeRoot() -> URL {
        if ProcessInfo.processInfo.environment["SOFTWARE_FACTORY_STORE"] == nil,
           let container = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: FileStore.appGroup) {
            return container.appending(path: "Store", directoryHint: .isDirectory)
        }
        return FileStore.defaultRoot()
    }

    /// One port, one address, every client. The factory is open while the app is running.
    static let port = FactoryServer.defaultPort
    static var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    /// Nobody is connected to a server that has just started. Agents from sessions that
    /// died with the last run would otherwise sit here marked connected for ever.
    /// (Alex, 12 Sep 2026.)
    private func clearConnections() {
        guard let store else { return }
        do {
            for var agent in try store.load().agents where agent.isConnected {
                agent.isConnected = false
                try store.save(agent)
            }
        } catch {
            storeError = error.localizedDescription
        }
    }

    // MARK: Refreshing

    private func start() {
        ticker?.cancel()
        ticker = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                self?.refresh()
                try? await _Concurrency.Task.sleep(for: Self.refreshEvery)
            }
        }
    }

    func refresh() {
        guard let store else { return }
        // What the floor looked like a moment ago, so a project that has just gone on
        // hold can be told from one that has been on hold all along. (T309.)
        let before = snapshot
        do {
            try loadState(from: store)
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
        // On hold means the work on it stops, however the hold was set: the Active
        // toggle here, or project_set from an agent. Start picks each of them back up
        // when the project comes off hold. (T309.)
        for agent in Sweep.agentsHeld(before: before, after: snapshot) { signalStop(agent) }
        // Work landing on a project where nobody is working pokes the first agent, so
        // filing a task and then going to find somebody to tell is one step rather than
        // two. Every route into the backlog comes through here: the add row, dictation,
        // an agent's own task_add, the phone. (T352.)
        // An agent with nothing to do and nothing coming costs a slot, a terminal and
        // whatever its CLI holds open. Stop picks back up, so this is safe to do without
        // asking. (T357.)
        for agent in Sweep.idleAgentsToStop(in: snapshot,
                                            messages: messagesByAgent.values.flatMap { $0 },
                                            working: busyAgents,
                                            now: .now) {
            signalStop(agent)
        }
        for agent in Sweep.agentsToPoke(before: before, after: snapshot,
                                        messages: messagesByAgent.values.flatMap { $0 },
                                        now: .now) {
            nudge(agent)
        }
        numberOldArtifacts()
        let gone = Sweep.stoppedAgents(in: snapshot, now: .now)
        let unblocked = Sweep.unblocked(in: snapshot, now: .now)
        // An agent working is silent, and silence says nothing about how it is going.
        // Once an hour the factory asks the ones that have not said. (T262.)
        let wanted = Sweep.statusReportsWanted(
            in: snapshot, messages: messagesByAgent.values.flatMap { $0 }, now: .now)
        if !gone.isEmpty || !unblocked.isEmpty || !wanted.messages.isEmpty {
            do {
                for a in gone.agents { try store.save(a) }
                for l in gone.leases { try store.save(l) }
                for t in unblocked { try store.save(t) }
                for a in wanted.agents { try store.save(a) }
                for m in wanted.messages { try store.save(m) }
                try loadState(from: store)
            } catch {
                storeError = error.localizedDescription
            }
        }
        // Bells rung while nobody was attached to the agent's terminal. The live path
        // through SwiftTerm only hears a bell when this app is holding that session, and
        // most agents work with nobody looking at them, so tmux leaves a mark instead and
        // this is where it is read. (Alex, 15 Sep 2026.)
        for session in Tmux.bellsRung() { ring(session: session) }
        dashboard = Dashboard.make(snapshot: snapshot)
        throttle = store.throttle()
        machine = MachineReading.sample()
        isAtTheMac = Presence.isAtTheMac
        notifier.notice(dashboard.openEscalations, projects: snapshot.projects)
        lastRefresh = .now
        _Concurrency.Task { await sync() }
    }

    /// Documents filed before reference numbers existed get one, oldest first, so R1 is
    /// the first thing ever written down here. One pass: after it there is nothing
    /// without a number, and the guard costs a scan of a list the app has just loaded.
    /// (T341.)
    private func numberOldArtifacts() {
        guard let store, snapshot.artifacts.contains(where: { $0.number == nil }) else { return }
        do {
            let every = (try? store.loadEveryArtifact()) ?? snapshot.artifacts
            var next = Artifacts.nextNumber(in: every)
            for var artifact in every.filter({ $0.number == nil }).sorted(by: { $0.added < $1.added }) {
                artifact.number = next
                next += 1
                try store.save(artifact)
            }
            try loadState(from: store)
        } catch {
            storeError = error.localizedDescription
        }
    }

    private func loadState(from store: FileStore) throws {
        let loaded = try store.load()
        var loadedMessages: [UUID: [AgentMessage]] = [:]
        for agent in loaded.agents {
            loadedMessages[agent.id] = try store.messages(for: agent.id)
        }
        snapshot = loaded
        messagesByAgent = loadedMessages
    }

    func askForNotifications() {
        _Concurrency.Task { await notifier.ask() }
    }

    func setThrottle(_ change: (inout Throttle) -> Void) {
        var t = throttle
        change(&t)
        throttle = t
        persist { try $0.save(t) }
    }

    /// The Mac's half of iCloud: every change goes up; decisions made on the phone come down.
    private func sync() async {
        guard cloud.isReady, let store else { return }
        await cloud.push(snapshot)
        if lastCloudPull.map({ Date.now.timeIntervalSince($0) < Self.pullDecisionsEvery }) ?? false { return }
        lastCloudPull = .now
        guard let theirs = await cloud.pullEscalations() else { return }
        let adopted = CloudRecords.decisionsToAdopt(local: snapshot.escalations, cloud: theirs)
        // Tasks added or changed on the phone away from the Mac: new ones get a
        // number if they arrived without one; parks, ranks and edits come across
        // when the cloud record is newer.
        let pulledTasks = await cloud.pullTasks() ?? []
        // Every task on disk, not the snapshot: the snapshot has no removed tasks in it,
        // and measured against that a task the person deleted looks like news from
        // another device, so the pull wrote it straight back. (T264.)
        let every = (try? store.loadEveryTask()) ?? snapshot.tasks
        let newTasks = CloudRecords.tasksToAdopt(local: every, cloud: pulledTasks)
        let changedTasks = CloudRecords.taskChangesToAdopt(local: every, cloud: pulledTasks)
        guard !adopted.isEmpty || !newTasks.isEmpty || !changedTasks.isEmpty else { return }
        do {
            for e in adopted { try store.save(e) }
            var nextNumber = Backlog.nextNumber(in: every)
            for var t in newTasks {
                if t.number == nil { t.number = nextNumber; nextNumber += 1 }
                try store.save(t)
            }
            for t in changedTasks { try store.save(t) }
            try loadState(from: store)
            dashboard = Dashboard.make(snapshot: snapshot)
        } catch {
            storeError = error.localizedDescription
        }
    }

    /// The Mac's verdict right now, for the dot beside Capacity and the page itself.
    var capacity: Capacity.Verdict? {
        machine.map { Capacity.verdict($0, throttle: throttle) }
    }

    /// Why it says that, in one line.
    var capacityReason: String? {
        machine.map { Capacity.reason($0, throttle: throttle) }
    }

    // MARK: Projects

    func project(for id: String) -> Project? {
        dashboard.projects.first { $0.id == id }?.project
    }

    func status(for id: String) -> Dashboard.ProjectStatus? {
        dashboard.projects.first { $0.id == id }
    }

    func messages(for agentID: UUID) -> [AgentMessage] {
        messagesByAgent[agentID] ?? []
    }

    /// Messages that have not been typed into a terminal yet, oldest first. A message to an
    /// agent with no terminal on screen stays here until one appears, rather than being
    /// thrown away at a window that was not open.
    func undelivered(for agentID: UUID) -> [AgentMessage] {
        messages(for: agentID).filter { $0.delivered == nil }.sorted { $0.sent < $1.sent }
    }

    /// Documents nobody has opened yet, across every project that is still here. (T373.)
    var unreadDocuments: Int {
        Waiting.unreadDocuments(snapshot.artifacts, on: snapshot.projects)
    }

    /// Messages still waiting to be typed into a terminal, for agents still on the
    /// floor. (T373.)
    var messagesWaiting: Int {
        Waiting.messages(messagesByAgent.values.flatMap { $0 }, to: snapshot.agents)
    }

    /// Throws one message away. The agent has already had it, or was never going to:
    /// either way the copy in the inbox is the person's to clear. (Alex, 14 Sep 2026.)
    func delete(_ message: AgentMessage) {
        persist { try $0.delete(message) }
    }

    /// Every task ever credited to this agent: the one it holds now, and whatever it
    /// finished before. Cleared only when a task goes back to the backlog or parked.
    /// What an agent is on. Finished work drops off: the page is for what it is doing,
    /// and a busy agent's list was mostly its own history. The project's backlog keeps
    /// every done task. (T224.)
    func tasks(assignedTo agentID: UUID) -> [FactoryTask] {
        snapshot.tasks
            .filter { $0.agentID == agentID && $0.removed == nil && $0.state != .done }
            .sorted { $0.updated > $1.updated }
    }

    /// Stops an agent where it stands. The floor could start one from the day it was
    /// built and had no way of ending one: Delete took the card away and left the agent
    /// working, which is the worst of both, and the only other way out was to find the
    /// window yourself.
    ///
    /// Its process gets SIGTERM, so it can put down what it is holding. The pane stays,
    /// because `remain-on-exit` keeps it: what the agent last said is usually why you
    /// stopped it. The record stays too, and reads as stopped on the next refresh, which
    /// is what hands back its leases and puts its task back on the backlog. Nothing here
    /// has to be written down: the kernel is the record. (T261.)
    func stop(_ agent: Agent) {
        guard signalStop(agent) else { return }
        refresh()
    }

    /// The signalling on its own, with no look afterwards, so the sweep can stop a whole
    /// project's agents from inside a refresh without starting another one. (T309.)
    @discardableResult
    private func signalStop(_ agent: Agent) -> Bool {
        guard Agents.mayStop(agent) else { return false }
        let pid = agent.pid
        let started = agent.pidStartedAt
        ProcessCheck.stop(pid: pid, startedAt: started)
        // SIGTERM is a request. An agent still there a few seconds later gets the signal
        // it cannot ignore: a Stop that leaves the agent working is worse than no Stop.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            ProcessCheck.stop(pid: pid, startedAt: started, signal: SIGKILL)
            self?.refresh()
        }
        return true
    }

    /// Takes an agent out of the factory for good. Whatever it was holding is freed, so a
    /// deleted agent never sits on a slot. The tasks it worked keep its name, and so do
    /// the notes it filed: a plan or a finding belongs to the project and is still true
    /// whoever wrote it.
    ///
    /// Its status reports go with it. A status report is the one document that is about
    /// the agent rather than about the project, so once the agent is gone it is a report
    /// by nobody, sitting on the Status reports page under a name that is not on the
    /// floor any more. (T310.)
    ///
    /// It is stopped first when there is a process to stop. A deleted agent that kept
    /// working was an agent nobody could see and nobody could reach: no card, no
    /// terminal, and still making calls. (T261.)
    func delete(_ agent: Agent) {
        stop(agent)
        persist { store in
            for lease in snapshot.leases where lease.agentID == agent.id && lease.released == nil {
                var ended = lease
                ended.released = .now
                try store.save(ended)
            }
            for report in Artifacts.statusReports(by: agent.id, in: snapshot.artifacts) {
                try store.delete(report)
            }
            try store.delete(agent)
        }
    }

    /// The agent's terminal set a title. That line is what the card shows.
    func setTitle(session: String, title: String) {
        guard let id = UUID(uuidString: session),
              var agent = snapshot.agents.first(where: { $0.id == id }) else { return }
        let title = Agent.preparedTitle(title)
        guard agent.title != title else { return }
        agent.title = title
        persist { try $0.save(agent) }
    }

    /// BEL: the agent wants a look. The card keeps the bell until it is opened.
    func ring(session: String) {
        guard let id = UUID(uuidString: session),
              var agent = snapshot.agents.first(where: { $0.id == id }),
              !agent.bel else { return }
        agent.bel = true
        persist { try $0.save(agent) }
    }

    func clearBell(_ agent: Agent) {
        guard agent.bel else { return }
        var agent = agent
        agent.bel = false
        persist { try $0.save(agent) }
    }

    /// A poke for an agent sitting waiting. It is a message like any other, and the app
    /// types every undelivered message into its agent's terminal.
    func nudge(_ agent: Agent) {
        sendMessage(to: agent.id, subject: "Nudge", contents: LaunchPrompt.nudge)
    }

    /// A message for an agent, written down so the app can type it into that agent's
    /// terminal.
    func sendMessage(to agentID: UUID, subject: String, contents: String) {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let contents = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contents.isEmpty else { return }
        let message = AgentMessage(recipientID: agentID, from: "Alex",
                                    subject: subject.isEmpty ? "A note from Alex" : subject, contents: contents)
        persist { try $0.save(message) }
    }

    /// A project is a name. The same name again is the same project.
    func addProject(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if snapshot.projects.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return }
        persist { try $0.save(Project(name: name)) }
    }

    /// Open tasks that stop a project being removed; the person moves or deletes them first.
    func openTasks(in project: Project) -> [FactoryTask] {
        snapshot.tasks.filter { $0.projectID == project.id && [.backlog, .inProgress, .blocked].contains($0.state) }
    }

    /// Nothing is deleted: the project's record stays, out of every list, its tasks with it.
    func removeProject(_ project: Project) {
        guard openTasks(in: project).isEmpty else { return }
        var p = project
        p.removed = .now
        persist { try $0.save(p) }
    }

    func setOnHold(_ project: Project, _ onHold: Bool) {
        var p = project
        p.onHold = onHold
        persist { try $0.save(p) }
    }

    func setPath(_ project: Project, _ path: String?) {
        var p = project
        p.path = path?.isEmpty == true ? nil : path
        persist { try $0.save(p) }
    }

    /// Writes the agent down before it starts, so it has a name, a card and a terminal
    /// from the moment the person clicks. The agent registers with this same id.
    /// Writes the agent down before anything launches. Its id is its session: the name
    /// of the terminal it will run in, the `--session-id` its CLI is started with, and
    /// what it says on every call it makes. (T-session, 13 Sep 2026.)
    func reserveAgent(for project: Project?) -> Agent? {
        guard let store else { return nil }
        if Agents.atCap(snapshot.agents, cap: Agents.cap(throttle)) {
            storeError = Agents.fullMessage(cap: Agents.cap(throttle))
            return nil
        }
        do {
            // The number comes off the factory's counter on disk, so the agent that
            // turns up in this session is the one on this card.
            let agent = Agents.reserve(number: try store.takeAgentNumber(),
                                       projectID: project?.id)
            try store.save(agent)
            refresh()
            return agent
        } catch {
            storeError = error.localizedDescription
            return nil
        }
    }

    /// `agent_create` asked the factory to start this one. The app launches it and
    /// this clears the flag so it is not started twice. (T179)
    func clearLaunchRequest(_ agent: Agent) {
        var a = agent
        guard a.wantsLaunch else { return }
        a.wantsLaunch = false
        persist { try $0.save(a) }
    }

    func noteError(_ message: String) {
        storeError = message
    }

    /// Writes down the process an agent is running in, once its terminal is up. The
    /// factory starts the agent, so it can find this out for itself rather than asking:
    /// that is what makes registering unnecessary, and it means an agent is watchable
    /// from the moment it launches rather than from whenever it gets round to saying
    /// hello. The looking happens off the main thread, because it runs tmux.
    /// (T-session, 13 Sep 2026.)
    func findTheProcess(for agent: Agent) {
        let session = agent.id.uuidString
        Task { [weak self] in
            let pid = await Task.detached(priority: .utility) {
                TerminalSessions.agentPID(session: session)
            }.value
            guard let self, let pid, let started = ProcessCheck.startTime(of: pid) else { return }
            self.persist { store in
                guard var found = try store.load().agents.first(where: { $0.id == agent.id }) else { return }
                found.pid = pid
                found.pidStartedAt = started
                try store.save(found)
            }
        }
    }

    /// How this agent is run, which decides how it is watched, talked to and stopped.
    func setRuntime(_ runtime: Agent.Runtime, for agent: Agent) {
        guard agent.runtime != runtime else { return }
        persist { store in
            guard var found = try store.load().agents.first(where: { $0.id == agent.id }) else { return }
            found.runtime = runtime
            try store.save(found)
        }
    }

    /// The session the ACP agent minted for itself, kept beside the factory's own id so
    /// its conversation can be picked back up. (T373.)
    func rememberACPSession(_ session: String?, for agent: Agent) {
        guard let session, agent.acpSession != session else { return }
        persist { store in
            guard var found = try store.load().agents.first(where: { $0.id == agent.id }) else { return }
            found.acpSession = session
            try store.save(found)
        }
    }

    /// What the daemon says about the agents it holds, written onto their records.
    ///
    /// Three things, and all three exist so that nothing downstream has to know ACP from
    /// tmux. The line it is showing goes into `title`, which every card, sidebar row and
    /// status board already reads, and which the OSC terminal title used to fill. Its
    /// process goes into `pid` and `pidStartedAt`, so `Agent.hasExited`, `Agents.mayStop`,
    /// `mayResume` and `Sweep.stoppedAgents` all keep working off the kernel exactly as
    /// they did. And the session it minted goes beside them. (T373.)
    func noteFloor(_ running: [AgentDaemon.Running]) {
        guard store != nil else { return }
        // Who is mid-turn, for the idle sweep. It is the one part of being busy that the
        // store cannot answer: a task record says nothing about a turn. (T373.)
        busyAgents = Set(running.filter(\.isPrompting).map(\.agent))
        for one in running {
            guard let agent = snapshot.agents.first(where: { $0.id == one.agent }) else { continue }
            let line = Agent.preparedTitle(one.line ?? "")
            let newPID = one.pid != nil && agent.pid != one.pid
            let newLine = !line.isEmpty && agent.title != line
            let newSession = one.session != nil && agent.acpSession != one.session
            guard newPID || newLine || newSession else { continue }
            let started = newPID ? one.pid.flatMap { ProcessCheck.startTime(of: $0) } : nil
            persist { store in
                guard var found = try store.load().agents.first(where: { $0.id == one.agent }) else { return }
                if newLine { found.title = line }
                if newSession { found.acpSession = one.session }
                if let started, let pid = one.pid {
                    found.pid = pid
                    found.pidStartedAt = started
                }
                try store.save(found)
            }
        }
    }

    /// Keeps the questions an ACP agent is blocked on and the floor's own escalations
    /// saying the same thing, in both directions.
    ///
    /// One place rather than one per way of answering. A permission request can be
    /// answered on the agent's page, on the Needs you strip, in a banner, on the phone or
    /// from the Lock Screen, and the last three go through CloudKit and the store without
    /// this app's views being involved at all. So nothing routes an answer to the daemon
    /// at the point it is given: this looks at what is decided and what is still waiting,
    /// and makes them agree.
    ///
    /// The one thing that makes these different from every other question is what an
    /// unanswered one costs. A question in a list is an agent carrying on with something
    /// else; this is an agent doing nothing at all. That is why the daemon takes the
    /// recommended option after `AgentDaemon.answerWithin` and why the recommendation is
    /// always allow once rather than allow always. (T373.)
    func syncPermissions(_ floor: Floor) {
        guard let store else { return }
        var wrote = false
        var waiting: Set<String> = []

        // The agent's own question, `elicitation/create`. The same thing
        // `escalation_raise` is, arriving down the other pipe, so it becomes the same
        // record and every page already knows how to draw it. Only Claude Code sends
        // them; the others answer in prose and end the turn. (T373.)
        for one in floor.held.values {
            guard let asked = one.asking else { continue }
            let reference = Self.questionReference(one.agent, asked.requestID)
            waiting.insert(reference)
            let already = snapshot.escalations.first { $0.reference == reference }
            if let already, let decision = already.decision {
                let picked = already.options.first { $0.id == decision.optionID }
                let value = picked.flatMap { title in
                    asked.options.first { $0.title == title.title }?.value
                }
                _Concurrency.Task {
                    await floor.answerQuestion(one.agent, request: asked.requestID,
                                               option: value, words: decision.note)
                }
                continue
            }
            guard already == nil else { continue }
            guard let agent = snapshot.agents.first(where: { $0.id == one.agent }),
                  let projectID = agent.projectID else { continue }
            var question = Escalation(
                projectID: projectID,
                question: asked.question,
                context: "It is waiting on your answer and doing nothing until it has one.",
                options: asked.options.map { Escalation.Option(title: $0.title, detail: $0.detail) },
                agentID: agent.id,
                raisedBy: agent.label)
            question.reference = reference
            try? store.save(question)
            wrote = true
        }

        for one in floor.held.values {
            guard let ask = one.waiting else { continue }
            let reference = Self.permissionReference(one.agent, ask.requestID)
            waiting.insert(reference)
            let already = snapshot.escalations.first { $0.reference == reference }

            // Answered somewhere, by anybody. Hand it to the agent, which has been
            // sitting on it since it asked.
            if let already, let decision = already.decision {
                let picked = already.options.first { $0.id == decision.optionID }
                let option = picked.flatMap { title in ask.options.first { $0.name == title.title } }
                    ?? ask.fallback
                if let option {
                    _Concurrency.Task { await floor.answer(one.agent, request: ask.requestID, option: option.optionID) }
                }
                continue
            }
            guard already == nil else { continue }
            guard let agent = snapshot.agents.first(where: { $0.id == one.agent }),
                  let projectID = agent.projectID else { continue }
            var question = Escalation(
                projectID: projectID,
                question: "\(agent.label) wants to \(Self.lowered(ask.title)).",
                context: "It is waiting on your answer and doing nothing until it has one.",
                options: ask.options.map {
                    Escalation.Option(title: $0.name, recommended: $0.optionID == ask.fallback?.optionID)
                },
                agentID: agent.id,
                raisedBy: agent.label)
            question.reference = reference
            try? store.save(question)
            wrote = true
        }

        // A question whose agent has stopped waiting, because the daemon ran out of
        // patience or because it was answered on the agent's own page, is closed rather
        // than left on the strip saying somebody has to do something.
        for var question in snapshot.escalations where question.isOpen {
            guard let reference = question.reference,
                  reference.hasPrefix(Self.permissionPrefix) || reference.hasPrefix(Self.questionPrefix),
                  !waiting.contains(reference), !question.options.isEmpty else { continue }
            try? question.decide(question.recommended ?? question.options[0], by: "the factory")
            try? store.save(question)
            wrote = true
        }
        if wrote { refresh() }
    }

    static let permissionPrefix = "acp-permission:"
    /// A question the agent asked, as opposed to a tool it asked about.
    static let questionPrefix = "acp-question:"

    static func permissionReference(_ agent: UUID, _ request: Int) -> String {
        "\(permissionPrefix)\(agent.uuidString):\(request)"
    }

    static func questionReference(_ agent: UUID, _ request: Int) -> String {
        "\(questionPrefix)\(agent.uuidString):\(request)"
    }

    /// "Write notes.md" reads as "wants to write notes.md" rather than "wants to Write".
    static func lowered(_ title: String) -> String {
        guard let first = title.first else { return title }
        return first.lowercased() + title.dropFirst()
    }

    /// Writes down which CLI started an agent. Its conversation lives in that one, under
    /// the session id the factory gave it, so a restart has to use the same. (T262.)
    func remember(_ kind: LaunchAgent, for agent: Agent) {
        guard agent.launchedWith != kind.rawValue else { return }
        persist { store in
            guard var found = try store.load().agents.first(where: { $0.id == agent.id }) else { return }
            found.launchedWith = kind.rawValue
            try store.save(found)
        }
    }

    /// Anything a shell has to take literally.
    nonisolated static func quoted(_ words: String) -> String {
        LaunchAgent.quoted(words)
    }

    /// Where a launched agent runs: in the app, where you can watch and type to it, or
    /// in Terminal, where it outlives the app.
    enum LaunchStyle: String, CaseIterable, Identifiable, Hashable {
        case embedded, terminal

        var id: String { rawValue }
        var title: String {
            switch self {
            case .embedded: "In the app"
            case .terminal: "In Terminal"
            }
        }
        var detail: String {
            switch self {
            case .embedded: "Watch it, and type to it, on the agent's page. It ends when this app quits."
            case .terminal: "A Terminal window of its own. It keeps working after this app quits."
            }
        }
    }

    static let launchStyleKey = "launchStyle"

    /// Whether a launched agent runs inside tmux, so it outlives this app. On when tmux
    /// is installed: it is old, dull and dependable, which zmux was not.
    /// (Alex, 12 Sep 2026.)
    nonisolated static let usesTmuxKey = "usesTmux"

    var usesTmux: Bool {
        get { UserDefaults.standard.object(forKey: Self.usesTmuxKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.usesTmuxKey) }
    }

    var launchStyle: LaunchStyle {
        get { LaunchStyle(rawValue: UserDefaults.standard.string(forKey: Self.launchStyleKey) ?? "") ?? .embedded }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.launchStyleKey) }
    }

    /// A project that only exists because an agent named it is written down the first
    /// time something is filed against it, so the record outlives the agent.
    private func ensureStored(_ projectID: String) {
        guard !snapshot.projects.contains(where: { $0.id == projectID }),
              let project = project(for: projectID) else { return }
        persist { try $0.save(project) }
    }

    // MARK: Backlog

    func tasks(for projectID: String) -> [FactoryTask] {
        Backlog.visible(for: projectID, in: snapshot.tasks)
    }

    func addTask(to projectID: String, title: String, at position: Backlog.Position = .bottom, note: String = "",
                 work: FactoryTask.Work = .implement) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        ensureStored(projectID)
        var task = FactoryTask(
            projectID: projectID, title: title, state: Backlog.state(for: position),
            rank: Backlog.rank(for: position, projectID: projectID, in: snapshot.tasks), note: note, work: work)
        persist { store in
            task.number = Backlog.nextNumber(in: (try? store.loadEveryTask()) ?? snapshot.tasks)
            try store.save(task)
        }
    }

    /// What was typed or dictated becomes a titled task: its first line is the title,
    /// anything after it the note. `position: .parked` lands it seen and set aside,
    /// never on the backlog.
    func addTask(to projectID: String, from text: String, at position: Backlog.Position) async {
        let drafted = await TaskTitler.draft(from: text)
        let parsed = FactoryTask.Work.reading(title: drafted.title)
        addTask(to: projectID, title: parsed.title, at: position, note: drafted.note, work: parsed.work)
    }

    /// The person parks and unparks. In progress and done are an agent's to say.
    func set(_ task: FactoryTask, to state: FactoryTask.State) {
        guard Backlog.personMaySet.contains(state) else { return }
        persist { try $0.save(Backlog.set(task, to: state)) }
    }

    func move(_ task: FactoryTask, to position: Backlog.Position) {
        var moved = task
        moved.rank = Backlog.rank(for: position, projectID: task.projectID, in: snapshot.tasks)
        moved.updated = .now
        persist { try $0.save(moved) }
    }

    func edit(_ task: FactoryTask, title: String, note: String, work: FactoryTask.Work? = nil) {
        let parsed = FactoryTask.Work.reading(title: title)
        let edited = Backlog.edit(task, title: parsed.title, note: note, work: work ?? parsed.work)
        guard edited != task else { return }
        persist { try $0.save(edited) }
    }

    /// Puts a task in one agent's name, so task_next hands it to that agent and nobody
    /// else. Nil takes the name off again.
    func assign(_ task: FactoryTask, to agent: Agent?) {
        let assigned = Backlog.assign(task, to: agent?.id, named: agent?.label, by: "Alex")
        guard assigned != task else { return }
        persist { try $0.save(assigned) }
    }

    /// Takes a task back off an agent that gave up or went quiet: onto the backlog, its
    /// name cleared, with a line saying who had it.
    func takeBack(_ task: FactoryTask) {
        let who = agentName(task.agentID)
        var back = Backlog.set(task, to: .backlog)
        back = Backlog.comment(on: back, who.map { "taken back from \($0)" } ?? "taken back", by: "Alex")
        persist { try $0.save(back) }
    }

    /// Nothing is deleted: the task is kept with the reason, out of every list.
    func delete(_ task: FactoryTask) {
        persist { try $0.save(Backlog.remove(task, why: "by Alex, in the app")) }
    }

    /// A document off the project. Nothing is deleted here either: the record stays with
    /// the reason, out of every list, so a plan an agent spent an afternoon on is still
    /// on disk after a mis-click. An agent could already take its own documents off with
    /// artifact_remove and the person could not, which left the project's page filling up
    /// with documents only the thing that wrote them could clear. (T266.)
    func delete(_ artifact: Artifact) {
        persist { try $0.save(Artifacts.remove(artifact, why: "by Alex, in the app")) }
    }

    /// The person has it open, so it is read.
    ///
    /// Written straight through rather than through `persist`, which refreshes: this is
    /// called from a view appearing, and a refresh from inside that redraws the page
    /// that is drawing. Nothing else is waiting on it, and the next poll is two seconds
    /// away. (T335.)
    func markRead(_ artifact: Artifact) {
        guard !artifact.isRead, let store else { return }
        do {
            try store.save(Artifacts.read(artifact))
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }

    func unblock(_ task: FactoryTask, _ blocker: FactoryTask.Blocker) {
        guard let index = task.blockers.firstIndex(of: blocker) else { return }
        guard let cleared = try? Backlog.unblock(task, matching: String(index + 1)) else { return }
        persist { try $0.save(cleared) }
    }

    /// A row dragged onto another: above it, among its own state (backlog or parked),
    /// crossing the line between them if that is where it landed.
    func place(_ task: FactoryTask, above other: FactoryTask) {
        guard task.id != other.id, Backlog.personMaySet.contains(other.state) else { return }
        var moved = task
        if moved.state != other.state {
            moved.state = other.state
            moved.agentID = nil
        }
        let siblings = tasks(for: task.projectID).filter { $0.state == other.state && $0.id != task.id }
        let changed = Backlog.place(moved, above: other, in: siblings + [moved], states: [other.state])
        persist { store in
            for t in changed { try store.save(t) }
            // place() only returns rows whose rank moved; a state change that landed on
            // the same rank it already had would otherwise go unsaved.
            if !changed.contains(where: { $0.id == moved.id }) { try store.save(moved) }
        }
    }

    // MARK: Escalations

    func escalations(for projectID: String) -> [Escalation] {
        snapshot.escalations.filter { $0.projectID == projectID }.sorted { $0.raised > $1.raised }
    }

    func agentName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return snapshot.agents.first { $0.id == id }?.label
    }

    /// Records the choice, with a note for the agent if there is one. The agent waiting
    /// on `escalation_await` sees it within a second.
    func decide(_ escalation: Escalation, _ option: Escalation.Option, note: String = "", by: String = "alex") {
        var e = escalation
        guard (try? e.decide(option, note: note, by: by)) != nil else { return }
        persist { try $0.save(e) }
        notifier.withdraw(e.id)
    }

    /// The answer in the person's own words, none of the options.
    func answer(_ escalation: Escalation, _ words: String, by: String = "alex") {
        var e = escalation
        guard (try? e.answer(words, by: by)) != nil else { return }
        persist { try $0.save(e) }
        notifier.withdraw(e.id)
    }

    // MARK: Resources

    func addResource(name: String, slots: Int, maxMinutes: Int) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        persist { try $0.save(Resource(name: name, slots: slots, maxLease: TimeInterval(maxMinutes * 60))) }
    }

    func remove(_ resource: Resource) {
        persist { store in
            for lease in snapshot.leases where lease.resourceID == resource.id { try store.delete(lease) }
            try store.delete(resource)
        }
    }

    /// Takes a lease back from an agent. The next lease it asks for will tell it so.
    func end(_ lease: Lease) {
        var ended = lease
        ended.released = .now
        persist { try $0.save(ended) }
    }

    // MARK: Developer

    func addSampleData() {
        persist { try SampleData.write(to: $0) }
    }

    // MARK: Plumbing

    func persist(_ write: (FileStore) throws -> Void) {
        guard let store else {
            writeError = "There is no store to write to."
            return
        }
        do {
            try write(store)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
        refresh()
    }

    /// The person has read it.
    func clearWriteError() { writeError = nil }
}
