#if os(macOS)
import Foundation
import Testing
@testable import SoftwareFactoryKit

/// The daemon, driven against a stub agent that speaks ACP and has no model in it. Real
/// processes, real pipes, real JSON: the only thing faked is the thinking. Everything
/// here is the part that would take the floor down if it were wrong. (T373.)
struct AgentFloorTests {
    static var stub: String {
        Bundle.module.url(forResource: "stub-agent", withExtension: "py", subdirectory: "Fixtures")?.path ?? ""
    }

    /// A store of its own per test, so nothing shares a transcript folder.
    static func scratch() throws -> (FileStore, URL) {
        let root = URL.temporaryDirectory.appending(path: "floor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try FileStore(root: root), root)
    }

    /// `mode` is an argument to the stub rather than an environment variable, because
    /// these tests run in parallel and setenv is process-global: one test's mode was
    /// being read by another's agent.
    static func floor(_ store: FileStore, mode: String = "plain", release: URL? = nil) -> AgentFloor {
        AgentFloor(store: store, searchPaths: ["/usr/bin", "/bin"], launch: { _ in
            LaunchAgent.ACPLaunch(command: stub, arguments: [mode] + (release.map { [$0.path] } ?? []))
        })
    }

    static func start(_ floor: AgentFloor, agent: UUID, cwd: URL, words: String = "hello there",
                      mode: String? = nil) async -> AgentDaemon.Reply {
        await floor.handle(AgentDaemon.Request(op: .start, agent: agent, kind: "copilot",
                                               cwd: cwd.path, text: words, mode: mode))
    }

    /// Turns the questions on, for a test about what happens when one is asked.
    static func asks(_ store: FileStore) throws {
        var throttle = store.throttle()
        throttle.permissions = .askAboutEverything
        try store.save(throttle)
    }

    /// Everything the factory has actually said to this agent, in order.
    static func asked(_ agent: UUID, in store: FileStore) -> [String] {
        ACPTranscript.folding(store.transcriptLines(for: agent))
            .entries.compactMap { entry in
                if case .asked(let text) = entry.kind { return text }
                return nil
            }
    }

    /// Waits for something to become true rather than sleeping a fixed amount: a test
    /// that sleeps is a test that is either slow or flaky and usually both.
    static func until(_ what: String, _ seconds: Double = 10, _ done: () -> Bool) async {
        let giveUp = Date().addingTimeInterval(seconds)
        while Date() < giveUp {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Gave up waiting for \(what).")
    }

    @Test func anAgentStartsAndSaysWhatItWasTold() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        let reply = await Self.start(floor, agent: agent, cwd: root, words: "read the backlog")
        #expect(reply.ok, "\(reply.error ?? "")")
        #expect(reply.session == "stub-session-1")

        await Self.until("the turn to finish") {
            ACPTranscript.folding(store.transcriptLines(for: agent)).lastSaid != nil
        }
        let page = ACPTranscript.folding(store.transcriptLines(for: agent))
        // Both sides of it: what the factory said, the tool, then what it said back.
        #expect(page.entries.first?.text == "read the backlog")
        #expect(page.entries.compactMap(\.tool).count == 1)
        #expect(page.lastSaid?.trimmingCharacters(in: .whitespaces) == "read the backlog")
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func whatTheFactorySaysToItIsInTheLogInOrder() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "first").ok)
        await Self.until("the first turn") {
            ACPTranscript.folding(store.transcriptLines(for: agent)).lastSaid != nil
        }
        #expect(await floor.handle(AgentDaemon.Request(op: .say, agent: agent, text: "second")).ok)
        await Self.until("the second turn") {
            ACPTranscript.folding(store.transcriptLines(for: agent)).entries.count >= 6
        }
        let asked = ACPTranscript.folding(store.transcriptLines(for: agent))
            .entries.compactMap { entry -> String? in
                if case .asked(let text) = entry.kind { return text }
                return nil
            }
        // The bug this locks down: two handles on one transcript, each with its own
        // offset, so the factory's own lines were written and then overwritten.
        #expect(asked == ["first", "second"])
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func lettingThemGetOnWithItAnswersForYou() async throws {
        let (store, root) = try Self.scratch()
        // The default, and what every agent was launched with before ACP.
        #expect(store.throttle().permissions == .allowEverything)
        let floor = Self.floor(store, mode: "permission")
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "make a note").ok)
        // It asked, the daemon said yes, and nothing ever reached the floor as a question.
        // Always rather than once: the person decided in advance, so the answer is a
        // standing one and the agent stops asking about this kind of thing. One round
        // trip rather than one per call. (Alex, 16 Sep 2026.)
        await Self.until("it to carry on") {
            ACPTranscript.folding(store.transcriptLines(for: agent)).entries
                .contains { $0.text?.contains("picked:allow_always") == true }
        }
        #expect(floor.everything().first?.waiting == nil)
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func askingAboutChangesLetsAReadThroughAndStopsAnEdit() async throws {
        let (store, root) = try Self.scratch()
        var throttle = store.throttle()
        throttle.permissions = .askAboutChanges
        try store.save(throttle)
        let floor = Self.floor(store, mode: "permission")
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "make a note").ok)
        // The stub asks about an edit, which changes something, so this one has to stop.
        await Self.until("the question") { floor.everything().first?.waiting != nil }
        #expect(floor.everything().first?.waiting?.kind == "edit")
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func aBlockedAgentIsReportedAsWaitingAndFreedByAnAnswer() async throws {
        do {
            let (store, root) = try Self.scratch()
            try Self.asks(store)
            let floor = Self.floor(store, mode: "permission")
            let agent = UUID()
            #expect(await Self.start(floor, agent: agent, cwd: root, words: "make a note").ok)

            await Self.until("the permission request") { floor.everything().first?.waiting != nil }
            let waiting = try #require(floor.everything().first?.waiting)
            #expect(waiting.title == "Write notes.md")
            #expect(waiting.kind == "edit")
            // Allow once, never allow always: a standing decision is not one to make for
            // somebody who is away from the Mac.
            #expect(waiting.fallback?.optionID == "allow_once")

            let answered = await floor.handle(AgentDaemon.Request(
                op: .permission, agent: agent, requestID: waiting.requestID, optionID: "allow_once"))
            #expect(answered.ok)
            await Self.until("the agent to carry on") {
                (ACPTranscript.folding(store.transcriptLines(for: agent)).entries
                    .contains { $0.text?.contains("picked:allow_once") == true })
            }
            #expect(floor.everything().first?.waiting == nil)
            _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
        }
    }

    @Test func answeringAQuestionItHasMovedOnFromIsRefused() async throws {
        do {
            let (store, root) = try Self.scratch()
            try Self.asks(store)
            let floor = Self.floor(store, mode: "permission")
            let agent = UUID()
            #expect(await Self.start(floor, agent: agent, cwd: root).ok)
            await Self.until("the permission request") { floor.everything().first?.waiting != nil }
            let no = await floor.handle(AgentDaemon.Request(
                op: .permission, agent: agent, requestID: 12345, optionID: "allow_once"))
            #expect(no.ok == false)
            #expect(no.error == "It has moved on from that question.")
            _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
        }
    }

    @Test func anAgentThatDiesIsStoppedRatherThanStillRunning() async throws {
        do {
            let (store, root) = try Self.scratch()
            let floor = Self.floor(store, mode: "crash")
            let agent = UUID()
            _ = await Self.start(floor, agent: agent, cwd: root)
            await Self.until("the child to go") { floor.everything().first?.isAlive == false }
            let one = try #require(floor.everything().first)
            #expect(one.exit == 3)
            #expect(one.pid == nil)
        }
    }

    @Test func stoppingLeavesTheTranscriptBehind() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "say this").ok)
        await Self.until("the turn") {
            ACPTranscript.folding(store.transcriptLines(for: agent)).lastSaid != nil
        }
        #expect(await floor.handle(AgentDaemon.Request(op: .stop, agent: agent)).ok)
        await Self.until("the child to go") { floor.everything().first?.isAlive == false }
        // What it last said is still readable, which is what leaving the tmux pane did.
        #expect(store.transcriptLines(for: agent).isEmpty == false)
        #expect(floor.everything().first?.state == .stopped)
    }

    @Test func aConversationIsPickedBackUpUnderItsOwnSession() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "first words").ok)
        await Self.until("the turn") {
            ACPTranscript.folding(store.transcriptLines(for: agent)).lastSaid != nil
        }
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
        await Self.until("the child to go") { floor.everything().first?.isAlive == false }
        let before = store.transcriptLines(for: agent).count

        let again = await floor.handle(AgentDaemon.Request(op: .resume, agent: agent, kind: "copilot",
                                                          cwd: root.path, text: "carry on"))
        #expect(again.ok, "\(again.error ?? "")")
        #expect(again.session == "stub-session-1", "It comes back as the same conversation.")
        // And the log is not started over: that is the conversation being picked up.
        #expect(store.transcriptLines(for: agent).count > before)
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func aFreshStartDoesNotInheritTheOldConversationsLog() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "old words").ok)
        await Self.until("the turn") {
            ACPTranscript.folding(store.transcriptLines(for: agent)).lastSaid != nil
        }
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
        await Self.until("the child to go") { floor.everything().first?.isAlive == false }

        #expect(await Self.start(floor, agent: agent, cwd: root, words: "new words").ok)
        await Self.until("the new turn") {
            ACPTranscript.folding(store.transcriptLines(for: agent)).lastSaid != nil
        }
        let page = ACPTranscript.folding(store.transcriptLines(for: agent))
        #expect(page.entries.contains { $0.text == "old words" } == false,
                "A new conversation under an old log reads as one that has lost its middle.")
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func startingOneThatIsAlreadyRunningIsRefused() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root).ok)
        let again = await Self.start(floor, agent: agent, cwd: root)
        #expect(again.ok == false)
        #expect(again.error?.contains("already running") == true)
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func theThingsThatCannotWorkSayWhyRatherThanFailing() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        #expect(await floor.handle(AgentDaemon.Request(op: .start, agent: nil)).error?.isEmpty == false)
        #expect(await floor.handle(AgentDaemon.Request(op: .start, agent: UUID(), cwd: "")).error
            == "An agent has to stand somewhere.")
        let nowhere = await floor.handle(AgentDaemon.Request(op: .start, agent: UUID(), cwd: "/no/such/folder"))
        #expect(nowhere.error == "There is no folder at /no/such/folder.")
        #expect(await floor.handle(AgentDaemon.Request(op: .say, agent: UUID(), text: "hi")).error
            == "Nobody here by that name.")
        #expect(await floor.handle(AgentDaemon.Request(op: .stop, agent: UUID())).error
            == "Nobody here by that name.")
        _ = root
    }

    @Test func oneTheDaemonCannotRunSaysSoRatherThanFailingQuietly() async throws {
        let (store, root) = try Self.scratch()
        let quiet = AgentFloor(store: store, launch: { _ in nil })
        let reply = await quiet.handle(AgentDaemon.Request(op: .start, agent: UUID(),
                                                           kind: "cursor", cwd: root.path))
        #expect(reply.error == "Cursor does not speak ACP.")
    }

    @Test func theLineTheCardShowsComesOffTheWire() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "look at the backlog").ok)
        await Self.until("something to show") { floor.everything().first?.line != nil }
        // What it last said, which is the words handed back. No OSC title anywhere.
        #expect(floor.everything().first?.line?.trimmingCharacters(in: .whitespaces) == "look at the backlog")
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func aDaemonThatCannotKeepARecordSaysSoRatherThanStartingAnyway() async throws {
        let (store, root) = try Self.scratch()
        #expect(store.canKeepTranscripts)
        // What a daemon started outside the app looks like against a group container it
        // is not allowed into.
        let folder = store.transcriptFolder
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(store.canKeepTranscripts == false)
        let reply = await Self.start(Self.floor(store), agent: UUID(), cwd: root)
        #expect(reply.ok == false)
        #expect(reply.error?.contains("could not keep a record") == true)
    }

    @Test func aTurnInFlightSaysSo() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store, mode: "slow")
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "take your time").ok)
        // The stub sleeps thirty seconds before it answers, so anything the page draws
        // about an agent being busy has to be true for that whole time.
        await Self.until("the turn to be reported as in flight") {
            floor.everything().first?.isPrompting == true
        }
        #expect(floor.everything().first?.isPrompting == true)
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func nothingIsSaidToAnAgentInTheMiddleOfATurn() async throws {
        let (store, root) = try Self.scratch()
        // The stub holds its turn open until this file appears, so the test decides when
        // the agent stops being busy. Sleeping for a guessed interval instead made this
        // race: the turn ended between the two things being said and the check.
        let release = root.appending(path: "let-it-finish")
        let floor = Self.floor(store, mode: "hold", release: release)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "first").ok)
        // The log is written on a queue of its own, so wait for the first to land rather
        // than assuming it has. (This raced before, and the race was in the test.)
        await Self.until("the first to be written down") { Self.asked(agent, in: store) == ["first"] }
        #expect(floor.everything().first?.isPrompting == true)

        // Two things to say while it is working. Both are taken and neither is said yet,
        // and the stub cannot finish until the gate file appears, so this cannot race.
        #expect(await floor.handle(AgentDaemon.Request(op: .say, agent: agent, text: "second")).ok)
        #expect(await floor.handle(AgentDaemon.Request(op: .say, agent: agent, text: "third")).ok)
        #expect(floor.everything().first?.queued == 2)
        #expect(Self.asked(agent, in: store) == ["first"], "Only the turn in flight has been said.")

        // Let it finish, and they go out one at a time as it frees up.
        FileManager.default.createFile(atPath: release.path, contents: nil)
        await Self.until("both to be said", 30) {
            Self.asked(agent, in: store) == ["first", "second", "third"]
        }
        #expect(floor.everything().first?.queued == 0)
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func aStoppedAgentForgetsWhatWasWaitingForIt() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store, mode: "hold", release: root.appending(path: "never"))
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "first").ok)
        await Self.until("the turn to be in flight") { floor.everything().first?.isPrompting == true }
        #expect(await floor.handle(AgentDaemon.Request(op: .say, agent: agent, text: "second")).ok)
        #expect(floor.everything().first?.queued == 1)
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
        // There is nobody left to say it to, and it must not be said to whatever starts
        // next under the same name.
        await Self.until("the queue to be given up") { floor.everything().first?.queued == 0 }
        #expect(floor.everything().first?.isPrompting == false)
    }

    /// The floor's setting is what an agent gets when nobody said otherwise. Left alone,
    /// with agents allowed to get on with it, this one goes into the most permissive mode
    /// it offers rather than the one it started in.
    @Test func anAgentWithNothingPickedFollowsTheFloor() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store, mode: "modes")
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root).ok)
        await Self.until("the mode to be set") {
            floor.everything().first?.mode == "bypassPermissions"
        }
    }

    /// A mode picked as the agent is started beats the floor's setting, and goes on
    /// beating it: the person said what this one agent is for while starting it. Plan is
    /// the case worth testing, because it is not what the floor would ever ask for.
    /// (T466.)
    @Test func aModePickedAtTheStartBeatsTheFloor() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store, mode: "modes")
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, mode: "plan").ok)
        await Self.until("the picked mode to be set") {
            floor.everything().first?.mode == "plan"
        }
        // And it stays there. The floor puts every agent back into the mode that matches
        // Settings on each `list`, which is the app's own refresh, and this one is not its
        // to move.
        _ = await floor.handle(AgentDaemon.Request(op: .list))
        #expect(floor.everything().first?.mode == "plan")
    }

    /// A mode this agent turns out not to offer is no mode at all. The written-down list
    /// in `LaunchAgent.modesOffered` can go stale when a CLI updates, and a stale menu row
    /// must cost a menu row rather than a start.
    @Test func aModeTheAgentDoesNotOfferLeavesTheFloorsSettingStanding() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store, mode: "modes")
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, mode: "yolo").ok)
        await Self.until("the floor's own mode to be set") {
            floor.everything().first?.mode == "bypassPermissions"
        }
    }

    @Test func aPingAnswersBeforeAnythingIsTouched() async throws {
        let (store, _) = try Self.scratch()
        let reply = await Self.floor(store).handle(AgentDaemon.Request(op: .ping))
        #expect(reply.ok)
        #expect(reply.pid == ProcessInfo.processInfo.processIdentifier)
    }
}

/// The wire, and the socket. Separate because these need no process at all.
struct AgentDaemonWireTests {
    @Test func aRequestSurvivesTheRoundTrip() throws {
        let sent = AgentDaemon.Request(op: .start, agent: UUID(), kind: "claudeCode",
                                       cwd: "/tmp", text: "go", requestID: 4, optionID: "allow_once")
        let back = try #require(AgentDaemon.decode(AgentDaemon.Request.self, from: AgentDaemon.encode(sent)))
        #expect(back == sent)
    }

    @Test func aReplySurvivesTheRoundTripWithItsDates() throws {
        let running = AgentDaemon.Running(agent: UUID(), state: .running, pid: 42, session: "s",
                                          startedAt: Date(timeIntervalSince1970: 1_758_000_000))
        let sent = AgentDaemon.Reply(ok: true, agents: [running], pid: 7)
        let back = try #require(AgentDaemon.decode(AgentDaemon.Reply.self, from: AgentDaemon.encode(sent)))
        #expect(back == sent)
        #expect(back.agents?.first?.startedAt == running.startedAt)
    }

    /// The daemon outlives the app, so a rebuilt app reads a daemon started hours ago. A
    /// field that daemon has never heard of is its default, not the end of the reply: the
    /// strict decoder threw on the whole `list` and the app drew a floor with nobody on
    /// it, while the agents were working the whole time. This is a real reply, off the
    /// socket, from a daemon that predates `takes` and `commands`.
    @Test func anOlderDaemonsReplyStillReads() throws {
        let line = """
        {"ok":true,"agents":[{"agent":"730B34A8-6555-4E8B-AB61-98B658A9FE66","state":"running",\
        "startedAt":"2026-09-15T17:46:48Z","isPrompting":true,"queued":0,"line":"Editing Models.swift",\
        "mode":"bypassPermissions","modes":[{"id":"bypassPermissions","name":"Bypass permissions",\
        "detail":"Accepts all permissions"}]}]}
        """
        let reply = try #require(AgentDaemon.decode(AgentDaemon.Reply.self, from: Data(line.utf8)))
        let one = try #require(reply.agents?.first)
        #expect(one.state == .running)
        #expect(one.modes.count == 1)
        #expect(one.mode == "bypassPermissions")
        #expect(one.line == "Editing Models.swift")
        // The ones it has never heard of, as their defaults rather than as a thrown reply.
        #expect(one.commands.isEmpty)
        #expect(one.takes == ACP.Attachments())
    }

    @Test func rubbishIsRefusedRatherThanCrashing() {
        #expect(AgentDaemon.decode(AgentDaemon.Request.self, from: Data("{".utf8)) == nil)
        #expect(AgentDaemon.decode(AgentDaemon.Request.self, from: Data()) == nil)
    }

    @Test func aPathTooLongForAUnixSocketIsAnAnswerAndNotACrash() {
        #expect(AgentSocket.makeAddress("/tmp/short.sock") != nil)
        #expect(AgentSocket.makeAddress("/" + String(repeating: "x", count: 200)) == nil)
    }

    @Test func theSocketDoesNotLiveUnderTheStore() {
        // A group container path spends most of the 104 characters a unix socket has.
        #expect(AgentDaemon.socketPath.contains(".local/state/software-factory"))
        #expect(AgentDaemon.socketPath.count < 104)
    }

    @Test func nothingListeningIsAnAnswerRatherThanAThrow() {
        let reply = AgentSocket.ask(AgentDaemon.Request(op: .ping),
                                    at: "/tmp/software-factory-nothing-here.sock", patience: 1)
        #expect(reply.ok == false)
        #expect(reply.error == AgentSocket.floorIsDown)
    }

    @Test func aQuestionNobodyAnswersHasAFallbackAndItIsAllowOnce() {
        let waiting = AgentDaemon.Pending(requestID: 1, title: "Run make", options: [
            ACP.PermissionOption(optionID: "always", name: "Always", kind: .allowAlways),
            ACP.PermissionOption(optionID: "once", name: "Once", kind: .allowOnce),
            ACP.PermissionOption(optionID: "no", name: "Deny", kind: .rejectOnce),
        ])
        #expect(waiting.fallback?.optionID == "once")
    }
}
#endif

/// What the factory does about something nobody answered. The two cases end differently
/// and the difference is the point. (T421.)
@Suite struct LateAnswerTests {
    private func running(waiting: AgentDaemon.Pending? = nil,
                         asking: AgentDaemon.Question? = nil) -> AgentDaemon.Running {
        var one = AgentDaemon.Running(agent: UUID(), state: .running)
        one.waiting = waiting
        one.asking = asking
        return one
    }

    private let long = Date().addingTimeInterval(-(AgentDaemon.answerWithin + 60))

    @Test func nothingIsDoneInsideTheTenMinutes() {
        let fresh = running(
            waiting: AgentDaemon.Pending(requestID: 1, title: "Write notes.md",
                                         options: [.init(optionID: "once", name: "Allow once", kind: .allowOnce)],
                                         asked: .now),
            asking: AgentDaemon.Question(requestID: 2, question: "Which way?",
                                         options: [.init(value: "a", title: "A", detail: "")],
                                         takesWords: true, asked: .now))
        #expect(AgentDaemon.late(in: fresh).isEmpty)
    }

    /// A permission takes the option the agent marked, which is always allow once.
    @Test func aPermissionNobodyAnsweredTakesTheRecommendation() {
        let one = running(waiting: AgentDaemon.Pending(
            requestID: 7, title: "Write notes.md",
            options: [.init(optionID: "once", name: "Allow once", kind: .allowOnce),
                      .init(optionID: "always", name: "Allow always", kind: .allowAlways)],
            asked: long))
        #expect(AgentDaemon.late(in: one) == [.allow(requestID: 7, optionID: "once")])
    }

    /// The agent's own question is given up on rather than answered. Nothing on the wire
    /// says which option it recommends, and picking the first one it listed would be the
    /// factory deciding for the person.
    @Test func aQuestionNobodyAnsweredIsDeclinedRatherThanDecided() {
        let one = running(asking: AgentDaemon.Question(
            requestID: 9, question: "Should the pages get a door or go?",
            options: [.init(value: "door", title: "Give them a door", detail: ""),
                      .init(value: "go", title: "Delete both", detail: "")],
            takesWords: true, asked: long))
        #expect(AgentDaemon.late(in: one) == [.decline(requestID: 9)])
    }

    @Test func bothAtOnceAreBothDealtWith() {
        let one = running(
            waiting: AgentDaemon.Pending(requestID: 1, title: "Write notes.md",
                                         options: [.init(optionID: "once", name: "Allow once", kind: .allowOnce)],
                                         asked: long),
            asking: AgentDaemon.Question(requestID: 2, question: "Which way?",
                                         options: [.init(value: "a", title: "A", detail: "")],
                                         takesWords: true, asked: long))
        #expect(AgentDaemon.late(in: one) == [.allow(requestID: 1, optionID: "once"), .decline(requestID: 2)])
    }
}
