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
    static func floor(_ store: FileStore, mode: String = "plain") -> AgentFloor {
        AgentFloor(store: store, searchPaths: ["/usr/bin", "/bin"], launch: { _ in
            LaunchAgent.ACPLaunch(command: stub, arguments: [mode])
        })
    }

    static func start(_ floor: AgentFloor, agent: UUID, cwd: URL, words: String = "hello there") async -> AgentDaemon.Reply {
        await floor.handle(AgentDaemon.Request(op: .start, agent: agent, kind: "copilot",
                                               cwd: cwd.path, text: words))
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
            ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store)).lastSaid != nil
        }
        let page = ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store))
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
            ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store)).lastSaid != nil
        }
        #expect(await floor.handle(AgentDaemon.Request(op: .say, agent: agent, text: "second")).ok)
        await Self.until("the second turn") {
            ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store)).entries.count >= 6
        }
        let asked = ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store))
            .entries.compactMap { entry -> String? in
                if case .asked(let text) = entry.kind { return text }
                return nil
            }
        // The bug this locks down: two handles on one transcript, each with its own
        // offset, so the factory's own lines were written and then overwritten.
        #expect(asked == ["first", "second"])
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func aBlockedAgentIsReportedAsWaitingAndFreedByAnAnswer() async throws {
        do {
            let (store, root) = try Self.scratch()
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
                (ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store)).entries
                    .contains { $0.text?.contains("picked:allow_once") == true })
            }
            #expect(floor.everything().first?.waiting == nil)
            _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
        }
    }

    @Test func answeringAQuestionItHasMovedOnFromIsRefused() async throws {
        do {
            let (store, root) = try Self.scratch()
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
            ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store)).lastSaid != nil
        }
        #expect(await floor.handle(AgentDaemon.Request(op: .stop, agent: agent)).ok)
        await Self.until("the child to go") { floor.everything().first?.isAlive == false }
        // What it last said is still readable, which is what leaving the tmux pane did.
        #expect(AgentDaemon.transcriptLines(for: agent, in: store).isEmpty == false)
        #expect(floor.everything().first?.state == .stopped)
    }

    @Test func aConversationIsPickedBackUpUnderItsOwnSession() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "first words").ok)
        await Self.until("the turn") {
            ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store)).lastSaid != nil
        }
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
        await Self.until("the child to go") { floor.everything().first?.isAlive == false }
        let before = AgentDaemon.transcriptLines(for: agent, in: store).count

        let again = await floor.handle(AgentDaemon.Request(op: .resume, agent: agent, kind: "copilot",
                                                          cwd: root.path, text: "carry on"))
        #expect(again.ok, "\(again.error ?? "")")
        #expect(again.session == "stub-session-1", "It comes back as the same conversation.")
        // And the log is not started over: that is the conversation being picked up.
        #expect(AgentDaemon.transcriptLines(for: agent, in: store).count > before)
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
    }

    @Test func aFreshStartDoesNotInheritTheOldConversationsLog() async throws {
        let (store, root) = try Self.scratch()
        let floor = Self.floor(store)
        let agent = UUID()
        #expect(await Self.start(floor, agent: agent, cwd: root, words: "old words").ok)
        await Self.until("the turn") {
            ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store)).lastSaid != nil
        }
        _ = await floor.handle(AgentDaemon.Request(op: .stop, agent: agent))
        await Self.until("the child to go") { floor.everything().first?.isAlive == false }

        #expect(await Self.start(floor, agent: agent, cwd: root, words: "new words").ok)
        await Self.until("the new turn") {
            ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store)).lastSaid != nil
        }
        let page = ACPTranscript.folding(AgentDaemon.transcriptLines(for: agent, in: store))
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

    @Test func anAgentThatDoesNotSpeakItSaysSo() async throws {
        let (store, root) = try Self.scratch()
        let quiet = AgentFloor(store: store, launch: { _ in nil })
        let reply = await quiet.handle(AgentDaemon.Request(op: .start, agent: UUID(), kind: "grok", cwd: root.path))
        #expect(reply.error == "Grok does not speak ACP.")
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
