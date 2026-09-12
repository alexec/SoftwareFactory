import Foundation
import Observation
import SoftwareFactoryKit

/// Owns the store and the floor built from it. Every rule lives in SoftwareFactoryKit; this is
/// the plumbing that keeps the window current.
@Observable
@MainActor
final class AppModel {
    private(set) var snapshot = Snapshot()
    private(set) var dashboard = Dashboard.empty
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

    static var registerCommand: String {
        "claude mcp add --transport http --scope user software-factory \(endpoint)"
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
            snapshot = try store.load()
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
        dashboard = Dashboard.make(snapshot: snapshot)
        throttle = store.throttle()
        machine = MachineReading.sample()
        isAtTheMac = Presence.isAtTheMac
        notifier.notice(dashboard.openEscalations, projects: snapshot.projects)
        lastRefresh = .now
        _Concurrency.Task { await sync() }
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
        guard !adopted.isEmpty else { return }
        do {
            for e in adopted { try store.save(e) }
            snapshot = try store.load()
            dashboard = Dashboard.make(snapshot: snapshot)
        } catch {
            storeError = error.localizedDescription
        }
    }

    // MARK: Projects

    func project(for id: String) -> Project? {
        dashboard.projects.first { $0.id == id }?.project
    }

    func status(for id: String) -> Dashboard.ProjectStatus? {
        dashboard.projects.first { $0.id == id }
    }

    func addProject(at url: URL) {
        persist { try $0.save(Project(path: url.path)) }
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

    func addTask(to projectID: String, title: String, kind: FactoryTask.Kind, at position: Backlog.Position = .bottom, note: String = "") {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        ensureStored(projectID)
        let task = FactoryTask(
            projectID: projectID, title: title, kind: kind,
            rank: Backlog.rank(for: position, projectID: projectID, in: snapshot.tasks), note: note)
        persist { try $0.save(task) }
    }

    /// What was typed or dictated becomes a titled task: Apple Intelligence shortens a
    /// long sentence to a title and keeps the rest as the note; a short one is the title.
    func addTask(to projectID: String, from text: String, at position: Backlog.Position) async {
        let drafted = await TaskTitler.draft(from: text)
        addTask(to: projectID, title: drafted.title, kind: drafted.kind, at: position, note: drafted.note)
    }

    func set(_ task: FactoryTask, to state: FactoryTask.State) {
        persist { try $0.save(Backlog.set(task, to: state)) }
    }

    func delete(_ task: FactoryTask) {
        persist { try $0.delete(task) }
    }

    func move(in projectID: String, from source: IndexSet, to destination: Int) {
        let changed = Backlog.move(in: tasks(for: projectID), from: source, to: destination)
        persist { store in for task in changed { try store.save(task) } }
    }

    // MARK: Escalations

    func escalations(for projectID: String) -> [Escalation] {
        snapshot.escalations.filter { $0.projectID == projectID }.sorted { $0.raised > $1.raised }
    }

    func agentName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return snapshot.agents.first { $0.id == id }?.name
    }

    /// Records the choice. The agent waiting on `escalation_await` sees it within a second.
    func decide(_ escalation: Escalation, _ option: Escalation.Option, by: String = "alex") {
        var e = escalation
        guard (try? e.decide(option, by: by)) != nil else { return }
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
