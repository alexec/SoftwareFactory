import Foundation
import Network
import Observation
import SoftwareFactoryKit

/// The phone is a remote for the factory on the Mac. It finds the factory over Bonjour,
/// reads the store through the factory's API every few seconds, and posts decisions.
@Observable
@MainActor
final class PhoneModel {
    enum Link: Equatable {
        case notYetAsked
        case looking
        case connected(name: String)
        case lost
    }

    private(set) var snapshot = Snapshot()
    private(set) var dashboard = Dashboard.empty
    private(set) var link: Link = .notYetAsked
    private(set) var factoryName: String?
    private(set) var lastError: String?
    /// Where the last snapshot came from.
    private(set) var source: Source = .none
    let cloud = CloudSync()
    let dictation = Dictation()
    let lockScreen = LockScreen()
    let notifier = PhoneNotifier()

    /// One model for the app and for the Lock Screen's buttons, which run in the app.
    static let shared = PhoneModel()

    enum Source: Equatable {
        case none
        case factory
        case cloud
    }

    var hasSeenIntro: Bool {
        didSet { UserDefaults.standard.set(hasSeenIntro, forKey: Self.introKey) }
    }
    var hasPrimedNetwork: Bool {
        didSet { UserDefaults.standard.set(hasPrimedNetwork, forKey: Self.primedKey) }
    }

    static let introKey = "hasSeenIntro"
    static let primedKey = "hasPrimedNetwork"
    static let serviceType = "_softwarefactory._tcp"
    static let pollEvery: Duration = .seconds(3)

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var client: FactoryClient?
    @ObservationIgnored private var poller: _Concurrency.Task<Void, Never>?

    private init() {
        hasSeenIntro = UserDefaults.standard.bool(forKey: Self.introKey)
        hasPrimedNetwork = UserDefaults.standard.bool(forKey: Self.primedKey)
        LockScreenDecider.handler = { escalationID, optionID in
            await PhoneModel.shared.decide(escalationID: escalationID, optionID: optionID)
        }
        _Concurrency.Task {
            await cloud.prepare()
            await notifier.refreshStanding()
            if !hasPrimedNetwork { startPolling() }
        }
        if hasPrimedNetwork { startLooking() }
    }

    // MARK: Finding the factory

    /// Starts browsing. The first call is what shows the system's local network alert,
    /// so it happens behind the primer's one button.
    func startLooking() {
        hasPrimedNetwork = true
        if client == nil { link = .looking }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            _Concurrency.Task { @MainActor in self?.found(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                _Concurrency.Task { @MainActor in self?.link = .lost }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        startPolling()
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard let result = results.first, case .service(let name, _, _, _) = result.endpoint else {
            if client != nil { link = .lost }
            return
        }
        client = FactoryClient(endpoint: result.endpoint, hostName: name)
        factoryName = name
        link = .connected(name: name)
        _Concurrency.Task { await poll() }
    }

    // MARK: Reading and deciding

    private func startPolling() {
        poller?.cancel()
        poller = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                await self?.poll()
                try? await _Concurrency.Task.sleep(for: Self.pollEvery)
            }
        }
    }

    /// The factory on the local network when it answers; iCloud otherwise.
    func poll() async {
        if let client {
            do {
                let response = try await client.send(HTTPRequest(method: "GET", path: "/api/snapshot"))
                guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
                snapshot = try FileStore.decoder.decode(Snapshot.self, from: response.body)
                dashboard = Dashboard.make(snapshot: snapshot)
                source = .factory
                lastError = nil
                if case .connected = link {} else { link = .connected(name: factoryName ?? "the Mac") }
                notifier.notice(dashboard.openEscalations, projects: snapshot.projects)
                await lockScreen.reflect(dashboard, factory: factoryName ?? "the Mac")
                return
            } catch {
                lastError = error.localizedDescription
                link = .lost
            }
        }
        guard cloud.isReady, let pulled = await cloud.pull() else { return }
        snapshot = pulled
        dashboard = Dashboard.make(snapshot: snapshot)
        source = .cloud
        notifier.notice(dashboard.openEscalations, projects: snapshot.projects)
        await lockScreen.reflect(dashboard, factory: factoryName ?? "the Mac")
    }

    /// A silent push from iCloud: something changed on the Mac. Read it all again; the
    /// banner, the lists and the Lock Screen follow from the read.
    func pushArrived() async {
        await poll()
    }

    func askForNotifications() {
        _Concurrency.Task { await notifier.ask() }
    }

    /// From a Lock Screen button. The question is in the last snapshot when the app has
    /// been running; after a cold start it is fetched from iCloud, or the factory if near.
    func decide(escalationID: UUID, optionID: UUID) async {
        if snapshot.escalations.isEmpty { await poll() }
        var found = snapshot.escalations.first { $0.id == escalationID }
        if found == nil, let pulled = await cloud.pullEscalations() {
            found = pulled.first { $0.id == escalationID }
        }
        guard let escalation = found, let option = escalation.options.first(where: { $0.id == optionID }) else { return }
        await decide(escalation, option)
        notifier.withdraw(escalationID)
        await lockScreen.reflect(dashboard, factory: factoryName ?? "the Mac")
    }

    func decide(_ escalation: Escalation, _ option: Escalation.Option, note: String = "") async {
        var e = escalation
        guard (try? e.decide(option, note: note, by: "alex, phone")) != nil else { return }
        await send(e, body: ["escalationID": escalation.id.uuidString, "optionID": option.id.uuidString, "note": note, "by": "alex, phone"])
    }

    /// The answer in the person's own words, none of the options.
    func answer(_ escalation: Escalation, _ words: String) async {
        var e = escalation
        guard (try? e.answer(words, by: "alex, phone")) != nil else { return }
        await send(e, body: ["escalationID": escalation.id.uuidString, "answer": e.decision?.note ?? words, "by": "alex, phone"])
    }

    /// The decided escalation goes to the factory when it answers, to iCloud otherwise.
    private func send(_ e: Escalation, body fields: [String: String]) async {
        guard source == .factory, let client else {
            await cloud.push(decision: e)
            if let i = snapshot.escalations.firstIndex(where: { $0.id == e.id }) {
                snapshot.escalations[i] = e
                dashboard = Dashboard.make(snapshot: snapshot)
                await lockScreen.reflect(dashboard, factory: factoryName ?? "the Mac")
            }
            return
        }
        let body = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        do {
            let response = try await client.send(HTTPRequest(
                method: "POST", path: "/api/decide", headers: ["Content-Type": "application/json"], body: body))
            guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
            await poll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Files a task through the factory. Only near the Mac for now; iCloud carries
    /// questions and decisions, not new tasks, until the Mac learns to adopt them.
    func addTask(to project: Project, title: String, at position: Backlog.Position) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, source == .factory, let client else { return }
        let drafted = await TaskTitler.draft(from: title)
        let body = (try? JSONSerialization.data(withJSONObject: [
            "project": project.id, "title": drafted.title, "kind": drafted.kind.rawValue,
            "note": drafted.note, "position": position.rawValue,
        ])) ?? Data()
        do {
            let response = try await client.send(HTTPRequest(
                method: "POST", path: "/api/task", headers: ["Content-Type": "application/json"], body: body))
            guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
            await poll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func project(for id: String) -> Project? {
        dashboard.projects.first { $0.id == id }?.project
    }

    /// A word for the agent on a project. Through the factory when near it; through
    /// iCloud otherwise, where the Mac picks it up within its next pull.
    func note(_ text: String, on project: Project) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if source == .factory, let client {
            let body = (try? JSONSerialization.data(withJSONObject: ["project": project.id, "text": text, "by": "alex, phone"])) ?? Data()
            do {
                let response = try await client.send(HTTPRequest(method: "POST", path: "/api/note", headers: ["Content-Type": "application/json"], body: body))
                guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
                await poll()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        let base = await cloud.pullProject(project.id) ?? project
        let noted = Steering.note(text, on: base, by: "alex, phone")
        await cloud.push(project: noted)
        if let i = snapshot.projects.firstIndex(where: { $0.id == project.id }) {
            snapshot.projects[i] = noted
            dashboard = Dashboard.make(snapshot: snapshot)
        }
    }
}
