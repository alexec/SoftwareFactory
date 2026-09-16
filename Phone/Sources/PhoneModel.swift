import Foundation
import Network
import Observation
import SoftwareFactoryKit

/// The phone is a remote for the factory on the Mac. It finds the factory over Bonjour,
/// reads the store through the factory's API every few seconds, and posts decisions.
@Observable
@MainActor
final class PhoneModel: Deciding {
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
    // MARK: Talking to an agent

    /// One agent's conversation, from the line the phone already has. Only over the
    /// network: a transcript is a file on the Mac and there is no copy in iCloud, so away
    /// from home the page says so rather than showing an empty conversation.
    /// (Alex, 16 Sep 2026.)
    func conversation(with agent: UUID, after: Int) async -> (lines: [String], total: Int)? {
        guard let client else { return nil }
        do {
            let response = try await client.send(HTTPRequest(
                method: "GET", path: "/api/transcript?agent=\(agent.uuidString)&after=\(after)"))
            guard response.status == 200 else { return nil }
            let read = try JSONDecoder().decode(HTTPRouter.Conversation.self, from: response.body)
            return (read.lines, read.total)
        } catch {
            return nil
        }
    }

    /// Words for an agent. It goes down as a message, which the Mac delivers the way it
    /// delivers a nudge, so the mailbox and the queueing behave as they already do and
    /// nothing is said to an agent in the middle of a turn.
    @discardableResult
    func say(_ words: String, to agent: UUID) async -> Bool {
        guard let client else { return false }
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return false }
        do {
            let body = try JSONEncoder().encode(HTTPRouter.Said(agent: agent, text: said))
            let response = try await client.send(HTTPRequest(
                method: "POST", path: "/api/say",
                headers: ["content-type": "application/json"], body: body))
            return response.status == 200
        } catch {
            return false
        }
    }

    /// Whether the Mac is in reach, which is what talking to an agent needs.
    var canTalkToAgents: Bool { client != nil }

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

    /// What the question's card says back. The card is drawn once for both apps and does
    /// not know that answering here is a round trip, so the waiting happens on this side
    /// of it. (T394.)
    func chose(_ escalation: Escalation, _ option: Escalation.Option, note: String) {
        _Concurrency.Task { await decide(escalation, option, note: note) }
    }

    func answered(_ escalation: Escalation, with words: String) {
        _Concurrency.Task { await answer(escalation, words) }
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

    /// Files a task through the factory when near it; through iCloud otherwise, the same
    /// as a decision or a note. The Mac adopts it, and gives it a number, on its next
    /// pull; here it has none until then.
    func addTask(to project: Project, title: String, at position: Backlog.Position) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let drafted = await TaskTitler.draft(from: title)
        let parsed = FactoryTask.Work.reading(title: drafted.title)
        if source == .factory, let client {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "project": project.id, "title": parsed.title,
                "note": drafted.note, "position": position.rawValue,
                "work": parsed.work.rawValue,
            ])) ?? Data()
            do {
                let response = try await client.send(HTTPRequest(
                    method: "POST", path: "/api/task", headers: ["Content-Type": "application/json"], body: body))
                guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
                await poll()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        guard cloud.isReady else { return }
        let task = FactoryTask(
            projectID: project.id, title: parsed.title,
            state: Backlog.state(for: position),
            rank: Backlog.rank(for: position, projectID: project.id, in: snapshot.tasks),
            note: drafted.note, work: parsed.work)
        await cloud.push(task: task)
        snapshot.tasks.append(task)
        dashboard = Dashboard.make(snapshot: snapshot)
    }

    func editTask(_ task: FactoryTask, title: String, note: String, work: FactoryTask.Work? = nil) async {
        let parsed = FactoryTask.Work.reading(title: title)
        let edited = Backlog.edit(task, title: parsed.title, note: note, work: work ?? parsed.work)
        guard edited != task else { return }
        if source == .factory, let client {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "id": edited.id.uuidString, "title": edited.title, "note": edited.note,
                "work": edited.work.rawValue,
            ])) ?? Data()
            do {
                let response = try await client.send(HTTPRequest(
                    method: "POST", path: "/api/task/edit", headers: ["Content-Type": "application/json"], body: body))
                guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
                await poll()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        guard cloud.isReady else { return }
        await cloud.push(task: edited)
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == edited.id }) else { return }
        snapshot.tasks[index] = edited
        dashboard = Dashboard.make(snapshot: snapshot)
    }

    /// Parks or unparks. In progress and done are an agent's to say.
    func set(_ task: FactoryTask, to state: FactoryTask.State) async {
        guard Backlog.personMaySet.contains(state) else { return }
        if source == .factory, let client {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "id": task.id.uuidString, "state": state.rawValue,
            ])) ?? Data()
            do {
                let response = try await client.send(HTTPRequest(
                    method: "POST", path: "/api/task/set", headers: ["Content-Type": "application/json"], body: body))
                guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
                await poll()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        guard cloud.isReady else { return }
        let updated = Backlog.set(task, to: state)
        await cloud.push(task: updated)
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == updated.id }) else { return }
        snapshot.tasks[index] = updated
        dashboard = Dashboard.make(snapshot: snapshot)
    }

    /// One row dropped onto another: above it, in that row's section.
    func place(_ task: FactoryTask, above other: FactoryTask) async {
        guard task.id != other.id, Backlog.personMaySet.contains(other.state) else { return }
        if source == .factory, let client {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "id": task.id.uuidString, "above": other.id.uuidString,
            ])) ?? Data()
            do {
                let response = try await client.send(HTTPRequest(
                    method: "POST", path: "/api/task/place", headers: ["Content-Type": "application/json"], body: body))
                guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
                await poll()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        guard cloud.isReady else { return }
        var moved = task
        if moved.state != other.state {
            moved.state = other.state
            moved.agentID = nil
        }
        let siblings = snapshot.tasks.filter { $0.projectID == task.projectID && $0.state == other.state && $0.id != task.id }
        let changed = Backlog.place(moved, above: other, in: siblings + [moved], states: [other.state])
        var saved = changed
        if !saved.contains(where: { $0.id == moved.id }) { saved.append(moved) }
        for t in saved {
            await cloud.push(task: t)
            if let i = snapshot.tasks.firstIndex(where: { $0.id == t.id }) { snapshot.tasks[i] = t }
            else { snapshot.tasks.append(t) }
        }
        dashboard = Dashboard.make(snapshot: snapshot)
    }

    /// Reorder within backlog or parked, the list's onMove.
    func move(ids: [UUID], to destination: Int, state: FactoryTask.State, projectID: String) async {
        guard Backlog.personMaySet.contains(state), !ids.isEmpty else { return }
        if source == .factory, let client {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "ids": ids.map(\.uuidString), "to": destination, "state": state.rawValue,
            ])) ?? Data()
            do {
                let response = try await client.send(HTTPRequest(
                    method: "POST", path: "/api/task/move", headers: ["Content-Type": "application/json"], body: body))
                guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
                await poll()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        guard cloud.isReady else { return }
        let open = snapshot.tasks.filter { $0.projectID == projectID && $0.state == state }.sorted(by: Backlog.order)
        var source = IndexSet()
        for id in ids {
            guard let i = open.firstIndex(where: { $0.id == id }) else { return }
            source.insert(i)
        }
        let changed = Backlog.move(in: open, from: source, to: destination, states: [state])
        for t in changed {
            await cloud.push(task: t)
            if let i = snapshot.tasks.firstIndex(where: { $0.id == t.id }) { snapshot.tasks[i] = t }
        }
        dashboard = Dashboard.make(snapshot: snapshot)
    }

    func project(for id: String) -> Project? {
        dashboard.projects.first { $0.id == id }?.project
    }

}
