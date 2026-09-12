import Foundation
import Observation
import ForemanKit

/// Owns the store, the Claude Code scan and the dashboard built from them. Every rule
/// lives in ForemanKit; this is the plumbing that keeps the window current.
@Observable
@MainActor
final class AppModel {
    private(set) var snapshot = Snapshot()
    private(set) var sessions: [AgentSession] = []
    private(set) var dashboard = Dashboard.empty
    private(set) var lastRefresh: Date?
    private(set) var storeError: String?

    let store: FileStore?
    var claudeFolder: ClaudeFolderAccess

    var hasSeenIntro: Bool {
        didSet { UserDefaults.standard.set(hasSeenIntro, forKey: Self.introKey) }
    }

    static let introKey = "hasSeenIntro"
    static let refreshEvery: Duration = .seconds(5)

    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() {
        hasSeenIntro = UserDefaults.standard.bool(forKey: Self.introKey)
        claudeFolder = ClaudeFolderAccess()
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

    // MARK: Refreshing

    private func start() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshEvery)
            }
        }
    }

    func refresh() async {
        if let store {
            do {
                snapshot = try store.load()
                storeError = nil
            } catch {
                storeError = error.localizedDescription
            }
        }
        sessions = await scanSessions()
        dashboard = Dashboard.make(snapshot: snapshot, sessions: sessions)
        lastRefresh = .now
    }

    private func scanSessions() async -> [AgentSession] {
        guard let root = claudeFolder.url else { return [] }
        let scanner = ClaudeCodeScanner(root: root)
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        return await Task.detached(priority: .utility) {
            (try? scanner.scan()) ?? []
        }.value
    }

    // MARK: Projects

    var projects: [Project] { dashboard.projects.map(\.project) }

    func project(for id: String) -> Project? {
        dashboard.projects.first { $0.id == id }?.project
    }

    func status(for id: String) -> Dashboard.ProjectStatus? {
        dashboard.projects.first { $0.id == id }
    }

    func addProject(at url: URL) {
        let project = Project(path: url.path)
        persist { try $0.save(project) }
    }

    /// A project that only exists because a session is in its folder is written down the
    /// first time something is filed against it, so the record outlives the session.
    private func ensureStored(_ projectID: String) {
        guard !snapshot.projects.contains(where: { $0.id == projectID }),
              let project = project(for: projectID) else { return }
        persist { try $0.save(project) }
    }

    // MARK: Backlog

    func items(for projectID: String) -> [WorkItem] {
        Backlog.items(for: projectID, in: snapshot.items)
    }

    func addItem(to projectID: String, title: String, kind: WorkItem.Kind) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        ensureStored(projectID)
        let item = WorkItem(
            projectID: projectID, title: title, kind: kind,
            rank: Backlog.nextRank(for: projectID, in: snapshot.items))
        persist { try $0.save(item) }
    }

    func set(_ item: WorkItem, to state: WorkItem.State) {
        persist { try $0.save(Backlog.set(item, to: state)) }
    }

    func set(_ item: WorkItem, kind: WorkItem.Kind) {
        var item = item
        item.kind = kind
        item.updated = .now
        persist { try $0.save(item) }
    }

    func delete(_ item: WorkItem) {
        persist { try $0.delete(item) }
    }

    func move(in projectID: String, from source: IndexSet, to destination: Int) {
        let changed = Backlog.move(in: items(for: projectID), from: source, to: destination)
        persist { store in for item in changed { try store.save(item) } }
    }

    // MARK: Escalations

    func escalations(for projectID: String) -> [Escalation] {
        snapshot.escalations.filter { $0.projectID == projectID }.sorted { $0.raised > $1.raised }
    }

    func decide(_ escalation: Escalation, _ option: Escalation.Option) {
        var e = escalation
        guard (try? e.decide(option)) != nil else { return }
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
        Task { await refresh() }
    }
}
