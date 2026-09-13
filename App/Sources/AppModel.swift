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
    private(set) var inboxes: [UUID: [AgentMessage]] = [:]
    private(set) var lastRefresh: Date?
    private(set) var storeError: String?

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

    nonisolated static let claudePluginCommand = """
    claude plugin marketplace add alexec/SoftwareFactory && \
    claude plugin install software-factory@software-factory-plugins
    """

    nonisolated static let copilotPluginCommand = "copilot plugin install alexec/SoftwareFactory:Plugins/software-factory"

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
        do {
            try loadState(from: store)
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
        let gone = Sweep.goneAgents(in: snapshot, now: .now)
        let unblocked = Sweep.unblocked(in: snapshot, now: .now)
        if !gone.isEmpty || !unblocked.isEmpty {
            do {
                for a in gone.agents { try store.save(a) }
                for l in gone.leases { try store.save(l) }
                for t in unblocked { try store.save(t) }
                try loadState(from: store)
            } catch {
                storeError = error.localizedDescription
            }
        }
        dashboard = Dashboard.make(snapshot: snapshot)
        throttle = store.throttle()
        machine = MachineReading.sample()
        isAtTheMac = Presence.isAtTheMac
        notifier.notice(dashboard.openEscalations, projects: snapshot.projects)
        lastRefresh = .now
        _Concurrency.Task { await sync() }
    }

    private func loadState(from store: FileStore) throws {
        let loaded = try store.load()
        var loadedInboxes: [UUID: [AgentMessage]] = [:]
        for agent in loaded.agents {
            loadedInboxes[agent.id] = try store.messages(for: agent.id)
        }
        snapshot = loaded
        inboxes = loadedInboxes
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
        // Tasks added on the phone away from the Mac: adopted with a number if they
        // arrived without one.
        let newTasks = (await cloud.pullTasks()).map { CloudRecords.tasksToAdopt(local: snapshot.tasks, cloud: $0) } ?? []
        guard !adopted.isEmpty || !newTasks.isEmpty else { return }
        do {
            for e in adopted { try store.save(e) }
            let every = (try? store.loadEveryTask()) ?? snapshot.tasks
            var nextNumber = Backlog.nextNumber(in: every)
            for var t in newTasks {
                if t.number == nil { t.number = nextNumber; nextNumber += 1 }
                try store.save(t)
            }
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

    func inbox(for agentID: UUID) -> [AgentMessage] {
        inboxes[agentID] ?? []
    }

    /// Every task ever credited to this agent: the one it holds now, and whatever it
    /// finished before. Cleared only when a task goes back to the backlog or parked.
    func tasks(assignedTo agentID: UUID) -> [FactoryTask] {
        snapshot.tasks.filter { $0.agentID == agentID && $0.removed == nil }.sorted { $0.updated > $1.updated }
    }

    /// Takes an agent out of the factory for good. Whatever it was holding is freed, so a
    /// deleted agent never sits on a slot. The tasks it worked keep its name.
    func delete(_ agent: Agent) {
        persist { store in
            for lease in snapshot.leases where lease.agentID == agent.id && lease.released == nil {
                var ended = lease
                ended.released = .now
                try store.save(ended)
            }
            try store.delete(agent)
        }
    }

    /// A note from the person, dropped straight into the agent's inbox.
    func sendMessage(to agentID: UUID, subject: String, contents: String) {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let contents = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contents.isEmpty else { return }
        let message = AgentMessage(recipientID: agentID, from: "Alex",
                                    subject: subject.isEmpty ? "A note from Alex" : subject, contents: contents)
        persist { try $0.save(message) }
    }

    /// A project is a name. The same name again is the same project.
    func addProject(named name: String, description: String, instructions: String = "") {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !description.isEmpty else { return }
        if snapshot.projects.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return }
        persist { try $0.save(Project(name: name, description: description, instructions: instructions)) }
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

    func setDescription(_ project: Project, _ description: String) {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        var p = project
        p.description = description
        persist { try $0.save(p) }
    }

    func setInstructions(_ project: Project, _ instructions: String) {
        var p = project
        p.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        persist { try $0.save(p) }
    }

    /// Which agent the person runs; Settings lets them switch it, and Launch agent
    /// uses it to pick the command.
    enum PreferredAgent: String, CaseIterable, Identifiable, Hashable {
        case claudeCode, copilot

        var id: String { rawValue }
        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .copilot: "GitHub Copilot"
            }
        }
        var installURL: URL {
            switch self {
            case .claudeCode: URL(string: "https://code.claude.com/docs/en/quickstart")!
            case .copilot: URL(string: "https://docs.github.com/en/copilot/get-started/cli-quickstart")!
            }
        }
        var setupCommand: String {
            switch self {
            case .claudeCode: AppModel.claudePluginCommand
            case .copilot: AppModel.copilotPluginCommand
            }
        }
        /// What Launch an agent runs, once the shell is already in the project's folder.
        /// The prompt names the project, so an agent starts on the right backlog without
        /// being asked. (Alex, 12 Sep 2026.) Given a task, it names that instead: the
        /// task is already in the agent's name, so it is told which one to claim.
        func launchCommand(for project: Project, task: FactoryTask? = nil, as name: String) -> String {
            if let task { return command(for: LaunchPrompt.task(task, in: project, as: name)) }
            return command(for: LaunchPrompt.project(project, as: name))
        }

        /// The same agent, told something else: a browser owner, a reviewer, whatever
        /// the person types.
        func command(for prompt: String) -> String {
            let quoted = AppModel.quoted(prompt)
            switch self {
            case .claudeCode: return "claude --permission-mode=auto \(quoted)"
            case .copilot: return "copilot --allow-all --interactive \(quoted)"
            }
        }
    }

    /// Writes the agent down before it starts, so it has a name, a card and a terminal
    /// from the moment the person clicks. The agent registers with this same id.
    func reserveAgent(for project: Project?, session: String) -> Agent? {
        guard let store else { return nil }
        do {
            // The number comes off the factory's counter on disk, so the agent that
            // registers with this name is the one on this card.
            let agent = Agents.reserve(number: try store.takeAgentNumber(),
                                       projectID: project?.id, session: session)
            try store.save(agent)
            refresh()
            return agent
        } catch {
            storeError = error.localizedDescription
            return nil
        }
    }

    /// Anything a shell has to take literally.
    nonisolated static func quoted(_ words: String) -> String {
        "'" + words.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    static let preferredAgentKey = "preferredAgent"

    var preferredAgent: PreferredAgent {
        get { PreferredAgent(rawValue: UserDefaults.standard.string(forKey: Self.preferredAgentKey) ?? "") ?? .claudeCode }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.preferredAgentKey) }
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

    func addTask(to projectID: String, title: String, at position: Backlog.Position = .bottom, note: String = "") {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        ensureStored(projectID)
        var task = FactoryTask(
            projectID: projectID, title: title, state: Backlog.state(for: position),
            rank: Backlog.rank(for: position, projectID: projectID, in: snapshot.tasks), note: note)
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
        addTask(to: projectID, title: drafted.title, at: position, note: drafted.note)
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

    /// A line from the person on a task, for the agent that picks it up next.
    func comment(on task: FactoryTask, _ text: String) {
        let noted = Backlog.comment(on: task, text, by: "Alex")
        guard noted.note != task.note else { return }
        persist { try $0.save(noted) }
    }

    func edit(_ task: FactoryTask, title: String, note: String) {
        let edited = Backlog.edit(task, title: title, note: note)
        guard edited != task else { return }
        persist { try $0.save(edited) }
    }

    /// Puts a task in one agent's name, so task_next hands it to that agent and nobody
    /// else. Nil takes the name off again.
    func assign(_ task: FactoryTask, to agent: Agent?) {
        let assigned = Backlog.assign(task, to: agent?.id, named: agent?.name, by: "Alex")
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

    func moveTask(_ task: FactoryTask, to project: Project) {
        ensureStored(project.id)
        persist { try $0.save(Backlog.move(task, to: project, from: self.project(for: task.projectID), in: snapshot.tasks)) }
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
        return snapshot.agents.first { $0.id == id }?.name
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

    private func persist(_ write: (FileStore) throws -> Void) {
        guard let store else { return }
        do {
            try write(store)
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
        refresh()
    }
}
