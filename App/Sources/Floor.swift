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
    /// How far into each agent's log the fold has got, in bytes. (T503.)
    @ObservationIgnored private var read: [UUID: Int] = [:]
    /// Where each agent's folded page starts, in bytes. Zero once the top of the log is on
    /// it. This is what scrolling back walks down. (T542.)
    @ObservationIgnored private var begins: [UUID: Int] = [:]
    /// One walk back at a time per agent, so a page that keeps asking while the first read
    /// is still running does not fold the same stretch twice.
    @ObservationIgnored private var walkingBack: Set<UUID> = []
    /// The agents whose log has been read at least once, so a page can tell an empty
    /// conversation from one it has not opened yet.
    @ObservationIgnored private var haveRead: Set<UUID> = []
    /// One fold at a time per agent. A fold now runs off the main actor, so a second look
    /// can start while the first is still reading, and both would fold the same bytes onto
    /// the same page.
    @ObservationIgnored private var folding: Set<UUID> = []

    init(store: FileStore?) {
        self.store = store
    }

    var isUp: Bool { daemonPID != nil }

    func running(_ agent: UUID) -> AgentDaemon.Running? { held[agent] }

    /// The page for this agent is open, so its transcript is worth folding on every
    /// refresh. Nothing else is: there may be sixteen agents and only one page.
    ///
    /// The first fold starts here rather than on the next poll. A poll is two seconds away,
    /// and the page's own call to `look()` gives up when one is already running, so opening
    /// an agent could sit on an empty page for two seconds having asked for nothing.
    /// (T511.)
    func watch(_ agent: UUID) {
        let isNew = watching.insert(agent).inserted
        guard isNew, read[agent] == nil else { return }
        Task { await refold(agent) }
    }
    func stopWatching(_ agent: UUID) { watching.remove(agent) }

    /// What has been folded for this agent so far. Empty for one whose log has not been
    /// read yet, which `hasBeenRead` tells apart from one with nothing in it.
    func transcript(_ agent: UUID) -> ACPTranscript {
        transcripts[agent] ?? ACPTranscript()
    }

    /// Whether this agent's log has been read at all. A page that says "Nothing yet" before
    /// anybody has looked is saying something it does not know. (T503.)
    func hasBeenRead(_ agent: UUID) -> Bool { haveRead.contains(agent) }

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
        for agent in watching { await refold(agent) }
    }

    /// Folds what has arrived since the last look onto what is already folded, off the main
    /// actor.
    ///
    /// It used to read the whole log and fold it from the beginning, on the main actor,
    /// every two seconds. Measured on this Mac: a busy agent's log is 30 MB over twelve
    /// thousand lines, and reading it takes 384 ms with 200 ms to fold, against about a
    /// millisecond for the daemon call beside it. So the page hitched for half a second
    /// twice a second while the window drew, which is the beachball tmux taught us about,
    /// arriving from the one direction nothing was watching. (T503.)
    ///
    /// Two fixes, and both are needed. The read and the fold are a pure function of a file,
    /// so they happen on a detached task and only the answer comes back. And a log only
    /// ever has lines appended, so only the new bytes are read and folded onto the page
    /// that is already there: an agent that has been running all day now costs the same as
    /// one that started a minute ago.
    private func refold(_ agent: UUID) async {
        guard let store else { return }
        guard !folding.contains(agent) else { return }
        folding.insert(agent)
        defer { folding.remove(agent) }
        // The first look at an agent opens at the end of its log rather than the start.
        // Every look after it takes what has arrived since, which is what T503 built.
        // (T511.)
        let opening = read[agent] == nil
        let from = read[agent] ?? 0
        let have = transcripts[agent] ?? ACPTranscript()
        let folded = await Task.detached(priority: .utility) { () -> (ACPTranscript, Int, Int?) in
            if opening {
                let open = ACPTranscript.opening(for: agent, in: store)
                return (open.page, open.read, open.from)
            }
            let tail = store.transcriptTail(for: agent, from: from)
            // Started again is a different conversation, so it is folded from nothing
            // rather than onto the one that was there.
            let base = tail.startedAgain ? ACPTranscript() : have
            guard !tail.lines.isEmpty else { return (base, tail.next, tail.startedAgain ? 0 : nil) }
            return (base.folding(more: tail.lines), tail.next, tail.startedAgain ? 0 : nil)
        }.value
        read[agent] = folded.1
        if let begin = folded.2 { begins[agent] = begin }
        haveRead.insert(agent)
        // Only when it is different: assigning the same page again is a redraw of every
        // row for nothing, and most looks bring no new lines.
        if transcripts[agent] != folded.0 { transcripts[agent] = folded.0 }
    }

    /// Whether there is more of this agent's conversation further back than the page holds.
    func hasEarlier(_ agent: UUID) -> Bool { (begins[agent] ?? 0) > 0 }

    /// Reads the stretch before the page and puts it in front. One step of scrolling back:
    /// call it again for the one before that, and `hasEarlier` says when to stop.
    ///
    /// Off the main actor like every other read, and one at a time per agent, because a page
    /// that asks again while the first read is still running would fold the same stretch
    /// twice and show every turn in it twice. (T542.)
    func readEarlier(_ agent: UUID) async {
        guard let store, !walkingBack.contains(agent) else { return }
        guard let before = begins[agent], before > 0 else { return }
        walkingBack.insert(agent)
        defer { walkingBack.remove(agent) }
        let have = transcripts[agent] ?? ACPTranscript()
        let grown = await Task.detached(priority: .utility) { () -> (ACPTranscript, Int) in
            let earlier = ACPTranscript.earlier(for: agent, in: store, before: before)
            return (have.following(earlier.page), earlier.from)
        }.value
        // The log may have been started again under us while this read: the page we grew
        // is the old conversation's and putting it back would undo the fresh start.
        guard begins[agent] == before else { return }
        begins[agent] = grown.1
        if transcripts[agent] != grown.0 { transcripts[agent] = grown.0 }
    }

    /// Forgets an agent's transcript, for one that has been deleted.
    func forget(_ agent: UUID) {
        transcripts[agent] = nil
        read[agent] = nil
        begins[agent] = nil
        haveRead.remove(agent)
        watching.remove(agent)
    }

    // MARK: Telling it things

    /// Starts an agent, or picks its conversation back up. Answers what went wrong, or
    /// nil when it started.
    func start(_ agent: Agent, kind: LaunchAgent, cwd: String, words: String,
               model: String = "", mode: String = "", resuming: Bool = false) async -> String? {
        guard await ensureDaemon() else { return trouble ?? "The agent daemon would not start." }
        let request = AgentDaemon.Request(op: resuming ? .resume : .start, agent: agent.id,
                                          kind: kind.rawValue, cwd: cwd, text: words,
                                          model: model.isEmpty ? nil : model,
                                          mode: mode.isEmpty ? nil : mode)
        let reply = await ask(request, patience: 180)
        guard reply.ok else { return reply.error }
        await look()
        return nil
    }

    /// Words for an agent: a nudge, a message, the status report ask. The same call for
    /// all of them, which is what the typed line was. Answers why it did not go, or nil
    /// when it went.
    ///
    /// It used to answer yes or no, and the page that a person types on threw the no away:
    /// the field emptied, nothing appeared, and "It is not running" was known here and said
    /// nowhere. The reason is the daemon's own words and they are the ones worth showing.
    /// (T495.)
    @discardableResult
    func say(_ words: String, to agent: UUID, files: [String] = []) async -> String? {
        let reply = await ask(AgentDaemon.Request(op: .say, agent: agent, text: words,
                                                  files: files.isEmpty ? nil : files))
        return reply.ok ? nil : (reply.error ?? "The daemon would not take it.")
    }

    func stop(_ agent: UUID) async {
        _ = await ask(AgentDaemon.Request(op: .stop, agent: agent))
        await look()
    }

    func cancel(_ agent: UUID) async {
        _ = await ask(AgentDaemon.Request(op: .cancel, agent: agent))
    }

    /// Joins everything waiting for this agent into one thing to say, so it goes as one
    /// turn rather than one turn each. Answers why it did not, or nil when it did.
    ///
    /// It answers rather than going quiet because the daemon outlives the app: it holds the
    /// agents, so it is not restarted when the app is rebuilt, and one running from before
    /// this op existed cannot decode the request and says so. A button that silently does
    /// nothing is worse than one that tells you why. (T541.)
    @discardableResult
    func merge(_ agent: UUID) async -> String? {
        let reply = await ask(AgentDaemon.Request(op: .merge, agent: agent))
        await look()
        if reply.ok { return nil }
        // A daemon from before this op existed cannot decode the request at all, and its
        // own words are about the wire rather than about anything the person can do.
        if reply.error == AgentDaemon.Reply.notARequest {
            return "The floor is holding your agents on an older daemon, which cannot do this yet. It picks it up when it next starts."
        }
        return reply.error ?? "The daemon would not merge them."
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
