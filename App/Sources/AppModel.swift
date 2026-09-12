import Foundation
import Observation
import ForemanKit

/// Owns the store and the floor built from it. Every rule lives in ForemanKit; this is
/// the plumbing that keeps the window current.
@Observable
@MainActor
final class AppModel {
    private(set) var snapshot = Snapshot()
    private(set) var dashboard = Dashboard.empty
    private(set) var lastRefresh: Date?
    private(set) var storeError: String?

    let store: FileStore?

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
    }

    /// The app group container when the sandbox gives us one, the plain path otherwise
    /// (the same folder, reached without the sandbox's help).
    static func storeRoot() -> URL {
        if ProcessInfo.processInfo.environment["FOREMAN_STORE"] == nil,
           let container = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: FileStore.appGroup) {
            return container.appending(path: "Store", directoryHint: .isDirectory)
        }
        return FileStore.defaultRoot()
    }

    /// The command that registers the MCP server with a client. The server is the
    /// `foreman` executable inside the app bundle, so it moves with the app.
    static var serverPath: String {
        Bundle.main.url(forAuxiliaryExecutable: "foreman-mcp")?.path ?? "foreman-mcp"
    }

    static var registerCommand: String {
        "claude mcp add --scope user foreman -- \"\(serverPath)\" mcp"
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
        lastRefresh = .now
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
        Backlog.tasks(for: projectID, in: snapshot.tasks)
    }

    func addTask(to projectID: String, title: String, kind: FactoryTask.Kind) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        ensureStored(projectID)
        let task = FactoryTask(
            projectID: projectID, title: title, kind: kind,
            rank: Backlog.nextRank(for: projectID, in: snapshot.tasks))
        persist { try $0.save(task) }
    }

    func set(_ task: FactoryTask, to state: FactoryTask.State) {
        persist { try $0.save(Backlog.set(task, to: state)) }
    }

    func set(_ task: FactoryTask, kind: FactoryTask.Kind) {
        var task = task
        task.kind = kind
        task.updated = .now
        persist { try $0.save(task) }
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
    func decide(_ escalation: Escalation, _ option: Escalation.Option) {
        var e = escalation
        guard (try? e.decide(option, by: "alex")) != nil else { return }
        persist { try $0.save(e) }
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
