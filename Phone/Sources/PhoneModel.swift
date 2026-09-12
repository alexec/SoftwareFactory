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

    init() {
        hasSeenIntro = UserDefaults.standard.bool(forKey: Self.introKey)
        hasPrimedNetwork = UserDefaults.standard.bool(forKey: Self.primedKey)
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

    func poll() async {
        guard let client else { return }
        do {
            let response = try await client.send(HTTPRequest(method: "GET", path: "/api/snapshot"))
            guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
            snapshot = try FileStore.decoder.decode(Snapshot.self, from: response.body)
            dashboard = Dashboard.make(snapshot: snapshot)
            lastError = nil
            if case .connected = link {} else { link = .connected(name: factoryName ?? "the Mac") }
        } catch {
            lastError = error.localizedDescription
            link = .lost
        }
    }

    func decide(_ escalation: Escalation, _ option: Escalation.Option) async {
        guard let client else { return }
        let body = (try? JSONSerialization.data(withJSONObject: [
            "escalationID": escalation.id.uuidString, "optionID": option.id.uuidString, "by": "alex, phone",
        ])) ?? Data()
        do {
            let response = try await client.send(HTTPRequest(
                method: "POST", path: "/api/decide", headers: ["Content-Type": "application/json"], body: body))
            guard response.status == 200 else { throw FactoryClient.ClientError.failed("The factory answered \(response.status).") }
            await poll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func project(for id: String) -> Project? {
        dashboard.projects.first { $0.id == id }?.project
    }
}
