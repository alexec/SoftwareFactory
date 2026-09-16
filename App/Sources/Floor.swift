import AppKit
import Observation
import SoftwareFactoryKit

/// The app's side of `software-factory agentd`. It starts the daemon when nothing is
/// answering, asks it what it is holding on the refresh the app already runs, and folds
/// each agent's transcript off disk.
///
/// Every call to the daemon goes off the main thread. It is a socket, and a socket that
/// is answered by a process that is spawning a child takes as long as that takes; asking
/// it while the window draws is the beachball tmux taught us about. (T373.)
@Observable
@MainActor
final class Floor {
    /// What the daemon says it is holding, as of the last look.
    private(set) var held: [UUID: AgentDaemon.Running] = [:]
    /// The daemon's own process, nil when nothing is answering.
    private(set) var daemonPID: Int32?
    /// Why the floor is down, when it is and it should not be.
    private(set) var trouble: String?
    /// One agent's transcript, folded, kept for the pages that are open. Read off the
    /// same file the daemon appends to, so a page has something to show the moment it
    /// opens and after the app has been rebuilt under it.
    private(set) var transcripts: [UUID: ACPTranscript] = [:]

    private let store: FileStore?
    @ObservationIgnored private var watching: Set<UUID> = []
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var startingDaemon = false
    @ObservationIgnored private var lengths: [UUID: Int] = [:]

    init(store: FileStore?) {
        self.store = store
    }

    var isUp: Bool { daemonPID != nil }

    func running(_ agent: UUID) -> AgentDaemon.Running? { held[agent] }

    /// The page for this agent is open, so its transcript is worth folding on every
    /// refresh. Nothing else is: there may be sixteen agents and only one page.
    func watch(_ agent: UUID) { watching.insert(agent) }
    func stopWatching(_ agent: UUID) { watching.remove(agent) }

    /// The whole transcript for an agent, folded now. For a page that has just opened and
    /// does not want to wait for the next refresh.
    func transcript(_ agent: UUID) -> ACPTranscript {
        transcripts[agent] ?? fold(agent)
    }

    // MARK: The refresh

    /// Asks the daemon what it is holding and folds the transcripts anybody is looking
    /// at. Safe to call as often as you like: one look runs at a time.
    func look() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        let reply = await Task.detached(priority: .utility) {
            AgentSocket.ask(AgentDaemon.Request(op: .list), patience: 5)
        }.value
        if reply.ok {
            daemonPID = reply.pid
            trouble = nil
            var byID: [UUID: AgentDaemon.Running] = [:]
            for one in reply.agents ?? [] { byID[one.agent] = one }
            if byID != held { held = byID }
        } else {
            daemonPID = nil
            trouble = reply.error == AgentSocket.floorIsDown ? nil : reply.error
        }
        for agent in watching { refold(agent) }
    }

    /// Folds an agent's log again, but only when the file has grown. Folding is cheap and
    /// reading a megabyte off disk every two seconds for a page nobody is scrolling is
    /// not. (T373.)
    private func refold(_ agent: UUID) {
        guard let store else { return }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: store.transcriptFile(for: agent).path)[.size] as? Int) ?? 0
        guard lengths[agent] != size else { return }
        lengths[agent] = size
        _ = fold(agent)
    }

    @discardableResult
    private func fold(_ agent: UUID) -> ACPTranscript {
        guard let store else { return ACPTranscript() }
        let page = ACPTranscript.folding(store.transcriptLines(for: agent))
        transcripts[agent] = page
        return page
    }

    /// Forgets an agent's transcript, for one that has been deleted.
    func forget(_ agent: UUID) {
        transcripts[agent] = nil
        lengths[agent] = nil
        watching.remove(agent)
    }

    // MARK: Telling it things

    /// Starts an agent, or picks its conversation back up. Answers what went wrong, or
    /// nil when it started.
    func start(_ agent: Agent, kind: LaunchAgent, cwd: String, words: String, resuming: Bool = false) async -> String? {
        guard await ensureDaemon() else { return trouble ?? "The agent daemon would not start." }
        let request = AgentDaemon.Request(op: resuming ? .resume : .start, agent: agent.id,
                                          kind: kind.rawValue, cwd: cwd, text: words)
        let reply = await ask(request, patience: 180)
        guard reply.ok else { return reply.error }
        await look()
        return nil
    }

    /// Words for an agent: a nudge, a message, the status report ask. The same call for
    /// all of them, which is what the typed line was.
    @discardableResult
    func say(_ words: String, to agent: UUID) async -> Bool {
        await ask(AgentDaemon.Request(op: .say, agent: agent, text: words)).ok
    }

    func stop(_ agent: UUID) async {
        _ = await ask(AgentDaemon.Request(op: .stop, agent: agent))
        await look()
    }

    func cancel(_ agent: UUID) async {
        _ = await ask(AgentDaemon.Request(op: .cancel, agent: agent))
    }

    /// The person picked this agent's mode. From here it stops following the floor's own
    /// setting: one agent in auto and another asking is the ordinary case.
    func setMode(_ agent: UUID, to mode: String) async {
        _ = await ask(AgentDaemon.Request(op: .mode, agent: agent, optionID: mode))
        await look()
    }

    /// The person answered the agent's own question. It has been blocked on this since
    /// it asked, so the words go back in the shape it asked in.
    func answerQuestion(_ agent: UUID, request: Int, option: String?, words: String) async {
        _ = await ask(AgentDaemon.Request(op: .answer, agent: agent, requestID: request,
                                          optionID: option, words: words))
        await look()
    }

    /// The person answered a permission request. The agent has been blocked on this.
    func answer(_ agent: UUID, request: Int, option: String) async {
        _ = await ask(AgentDaemon.Request(op: .permission, agent: agent,
                                          requestID: request, optionID: option))
        await look()
    }

    private func ask(_ request: AgentDaemon.Request, patience: TimeInterval = 20) async -> AgentDaemon.Reply {
        await Task.detached(priority: .userInitiated) {
            AgentSocket.ask(request, patience: patience)
        }.value
    }

    // MARK: Keeping it up

    /// Starts the daemon if nothing is answering, and waits for it to answer. Called
    /// before a launch rather than on a timer: a Mac with no agents on it needs no
    /// daemon, and starting one just in case is a process in the person's activity
    /// monitor doing nothing.
    @discardableResult
    func ensureDaemon() async -> Bool {
        if isUp { return true }
        guard !startingDaemon else { return isUp }
        // Sandboxed, a child would inherit the sandbox and lose ~/.claude, the keychain
        // and every tool an agent runs, so there is nothing to start. The store build
        // says so rather than pretending.
        guard !AgentLauncher.isSandboxed else {
            trouble = "This build is sandboxed, so it cannot hold agents. Use the direct download."
            return false
        }
        guard let binary = Self.binary else {
            trouble = "software-factory is not on this Mac. Build it with: swift build --package-path Packages/SoftwareFactoryKit"
            return false
        }
        startingDaemon = true
        defer { startingDaemon = false }
        let started = await Task.detached(priority: .userInitiated) { Self.spawnDaemon(binary) }.value
        if started {
            await look()
        } else {
            trouble = "The agent daemon would not start."
        }
        return started
    }

    /// Spawns the daemon and waits for it to answer. Sync on purpose: it sleeps, and
    /// `Thread.sleep` is not allowed in an async context, so this is the whole of the
    /// blocking part and it runs on a detached task.
    private nonisolated static func spawnDaemon(_ binary: String) -> Bool {
        // Already there, started by a shell or by a previous run of this app.
        if AgentSocket.isUp() { return true }
        let daemon = Process()
        daemon.executableURL = URL(filePath: binary)
        daemon.arguments = ["agentd"]
        // Nothing of ours on its pipes, so it is not holding this app's file handles and
        // nothing fills up behind it.
        daemon.standardInput = FileHandle.nullDevice
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        do { try daemon.run() } catch { return false }
        let giveUp = Date().addingTimeInterval(10)
        while Date() < giveUp {
            if AgentSocket.isUp() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Where `software-factory` is. Beside the app first, so a build that ships the
    /// daemon uses its own; then the package's own build output, which is what a Debug
    /// run off this checkout has; then the usual places.
    static var binary: String? {
        var places: [String] = []
        if let told = ProcessInfo.processInfo.environment["SOFTWARE_FACTORY_BIN"] {
            places.append(told)
        }
        places.append(Bundle.main.bundleURL.appending(path: "Contents/MacOS/software-factory").path)
        places.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appending(path: "software-factory").path)
        #if DEBUG
        // A Debug run is off the checkout, and the daemon there is the one `swift test`
        // just built. Walking up from the app in DerivedData does not find the source
        // tree, so this is the checkout as it sits on this Mac.
        places.append("\(NSHomeDirectory())/SoftwareFactory/Packages/SoftwareFactoryKit/.build/out/Products/Debug/software-factory")
        places.append("\(NSHomeDirectory())/SoftwareFactory/Packages/SoftwareFactoryKit/.build/debug/software-factory")
        #endif
        places.append(contentsOf: [
            "\(NSHomeDirectory())/.local/bin/software-factory",
            "/opt/homebrew/bin/software-factory",
            "/usr/local/bin/software-factory",
        ])
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
