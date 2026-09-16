import Foundation
import Testing
@testable import SoftwareFactoryKit

/// Every one of these runs against a recording of a real `copilot --acp` session, in
/// `Fixtures/copilot-session.jsonl`, because the published schema and the wire disagree
/// in places that would have cost a day each: the permission outcome is `selected` and
/// not `Approved`, a turn ends `end_turn` and not `Completed`. (T373.)
struct ACPTests {
    static let recording: [String] = {
        guard let url = Bundle.module.url(forResource: "copilot-session", withExtension: "jsonl",
                                          subdirectory: "Fixtures"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map(String.init)
    }()

    @Test func theRecordingIsThere() {
        #expect(Self.recording.count > 50)
    }

    @Test func aParseFailureIsALineAndNotACrash() {
        guard case .unrecognised = ACP.read(line: "{not json") else {
            Issue.record("A bad line has to come back as itself.")
            return
        }
        guard case .unrecognised = ACP.read(line: "") else {
            Issue.record("An empty line has to come back as itself.")
            return
        }
    }

    @Test func everyLineOfTheRecordingIsPlaced() {
        var unrecognised: [String] = []
        for line in Self.recording {
            if case .unrecognised(let raw) = ACP.read(line: line) { unrecognised.append(raw) }
        }
        #expect(unrecognised.isEmpty, "Unplaced: \(unrecognised.prefix(2))")
    }

    @Test func theAgentAnswersWithWhatItCanDo() throws {
        let line = try #require(Self.recording.first)
        guard case .response(let id, let result, let error) = ACP.read(line: line) else {
            Issue.record("The first line is the answer to initialize.")
            return
        }
        #expect(id == 1)
        #expect(error == nil)
        let body = try JSONSerialization.jsonObject(with: try #require(result)) as? [String: Any]
        #expect(body?["protocolVersion"] as? Int == ACP.protocolVersion)
    }

    @Test func aToolCallCarriesItsKindAndWhereItIs() throws {
        let calls = Self.recording.compactMap { line -> ACP.ToolCall? in
            guard case .update(_, .tool(let call)) = ACP.read(line: line) else { return nil }
            return call.title == nil ? nil : call
        }
        let read = try #require(calls.first { $0.kind == .read })
        #expect(read.status == .pending)
        #expect(read.locations?.first?.path.hasSuffix("hello.txt") == true)
        #expect(read.heading.contains("hello.txt"))
    }

    @Test func aDiffArrivesAsADiff() throws {
        let diffs = Self.recording.compactMap { line -> ACP.Diff? in
            guard case .update(_, .tool(let call)) = ACP.read(line: line) else { return nil }
            for content in call.content ?? [] {
                if case .diff(let diff) = content { return diff }
            }
            return nil
        }
        let diff = try #require(diffs.first)
        #expect(diff.fileName == "note.md")
        #expect(diff.newText.contains("hello from the factory"))
        #expect(diff.counts.added == 2)
    }

    @Test func aPermissionRequestKnowsWhatToRecommend() throws {
        let asks = Self.recording.compactMap { line -> (Int, ACP.PermissionRequest)? in
            guard case .permission(let id, let ask) = ACP.read(line: line) else { return nil }
            return (id, ask)
        }
        let (id, ask) = try #require(asks.first)
        #expect(id == 0)
        #expect(ask.options.count == 3)
        // Allow once, not allow always: a standing decision is not one to make for
        // somebody because they were away from the Mac.
        #expect(ask.recommended?.optionID == "allow_once")
        #expect(ask.denial?.kind == .rejectOnce)
        #expect(ask.toolCall.kind == .edit)
        #expect(ask.toolCall.kind?.changesAnything == true)
    }

    @Test func readingIsNeverWorthAsking() {
        #expect(ACP.ToolCall.Kind.read.changesAnything == false)
        #expect(ACP.ToolCall.Kind.search.changesAnything == false)
        #expect(ACP.ToolCall.Kind.execute.changesAnything == true)
        #expect(ACP.ToolCall.Kind.delete.changesAnything == true)
        // A kind the protocol adds next year is treated as though it changes something.
        #expect(ACP.ToolCall.Kind.other.changesAnything == true)
    }

    @Test func anUnknownKindIsOtherRatherThanAThrow() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"c1","kind":"telepathy","status":"whatever"}}}"#
        guard case .update(_, .tool(let call)) = ACP.read(line: line) else {
            Issue.record("An unknown kind must still be a tool call.")
            return
        }
        #expect(call.kind == .other)
        #expect(call.status == .pending)
    }

    @Test func aNotificationIsNotTheSameThingAsALineWeCouldNotRead() {
        // `_auth/status_update` wants no answer. Calling it unreadable would have the
        // client worrying about a line that is simply not addressed to it.
        guard case .notification(let method) = ACP.read(line: #"{"jsonrpc":"2.0","method":"_auth/status_update","params":{}}"#) else {
            Issue.record("A method with no id is a notification.")
            return
        }
        #expect(method == "_auth/status_update")
    }

    /// The recording carries an `available_commands_update`, which is read as commands
    /// now rather than kept as an unknown (T436). Anything we still do not draw goes
    /// through as itself, so the raw log stays honest.
    @Test func whatWeDoNotDrawIsKeptRatherThanDropped() {
        let commands = Self.recording.compactMap { line -> [ACP.Command]? in
            guard case .update(_, .commands(let listed)) = ACP.read(line: line) else { return nil }
            return listed
        }
        #expect(!commands.isEmpty)
        guard case .update(_, .other(let kind)) = ACP.read(
            line: #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"something_later"}}}"#
        ) else {
            Issue.record("An update we have never seen is still an update."); return
        }
        #expect(kind == "something_later")
    }

    @Test func aLaterUpdateDoesNotWipeWhatTheFirstOneSaid() {
        let first = ACP.ToolCall(toolCallID: "c1", title: "Editing Models.swift", kind: .edit, status: .pending)
        let later = ACP.ToolCall(toolCallID: "c1", status: .completed,
                                 content: [.diff(ACP.Diff(path: "/a/Models.swift", oldText: "", newText: "x\n"))])
        let merged = first.merged(with: later)
        #expect(merged.title == "Editing Models.swift")
        #expect(merged.kind == .edit)
        #expect(merged.status == .completed)
        #expect(merged.content?.count == 1)
        #expect(merged.isFinished)
    }

    @Test func weTellTheAgentWhereTheFactoryIs() throws {
        let server = ACP.factoryServer()
        #expect(server["type"] as? String == "http")
        #expect(server["url"] as? String == "http://127.0.0.1:4747/mcp")
        // Empty, but there. A missing headers field is "Invalid params" and no clue
        // which field was meant.
        #expect(server["headers"] as? [Any] != nil)
    }

    @Test func ourAnswerIsTheShapeTheWireWants() throws {
        let answer = ACP.permissionAnswer(optionID: "allow_once")
        let outcome = try #require(answer["outcome"] as? [String: Any])
        // Not "Approved". The documentation says Approved and the agent says selected.
        #expect(outcome["outcome"] as? String == "selected")
        #expect(outcome["optionId"] as? String == "allow_once")
    }

    @Test func aStopReasonSaysSomethingOnlyWhenItIsNotTheOrdinaryOne() {
        #expect(ACP.StopReason("end_turn").note == nil)
        #expect(ACP.StopReason("max_tokens").note == "It ran out of context.")
        #expect(ACP.StopReason(nil) == .unknown)
        #expect(ACP.StopReason("something new").note == nil)
    }
}

/// What the help page is built from. The launch popover shows none of this any more:
/// it is a working screen, and a paragraph you read and dismiss every time you start an
/// agent is a paragraph in the way. (Alex, 16 Sep 2026.)
struct LaunchAgentHelpTests {
    @Test func everyOneSaysWhatItIs() {
        for agent in LaunchAgent.allCases {
            #expect(!agent.explanation.isEmpty, "\(agent.title) says nothing about itself.")
            #expect(!agent.title.isEmpty)
        }
    }

    @Test func everyOneNeedsSomewhereToBeGotFrom() {
        for agent in LaunchAgent.allCases {
            #expect(agent.installURL != nil)
        }
    }

    @Test func anACPAgentIsHandedTheFactoryRatherThanRegisteringWithIt() {
        // No plugin install for one that speaks ACP: `session/new` carries the MCP
        // server, so the marketplace dance is somebody else's problem now.
        for agent in LaunchAgent.allCases where agent.speaksACP {
            #expect(agent.setUp.contains { $0.what.contains("Register") } == false)
        }
        // Claude Code speaks it through an adapter you install; the other three have it
        // built in and so have nothing to set up beyond themselves.
        #expect(LaunchAgent.claudeCode.setUp.map(\.what) == ["The part that speaks ACP"])
        for agent in [LaunchAgent.copilot, .grok, .cursor] {
            #expect(agent.setUp.isEmpty, "\(agent.title) should need nothing extra.")
        }
    }

    @Test func everyAgentSpeaksIt() {
        // Checked by handshaking with each binary rather than by grepping its help,
        // which found two and missed the two that put it behind a subcommand. A shell was
        // in this list and never belonged: it is opened beside an agent now rather than
        // instead of one. (Alex, 16 Sep 2026.)
        for agent in LaunchAgent.allCases {
            #expect(agent.speaksACP, "\(agent.title) has to speak ACP.")
            #expect(agent.installURL != nil)
        }
    }

    @Test func eachOneIsStartedByItsOwnWord() {
        #expect(LaunchAgent.claudeCode.acp?.arguments == [])
        #expect(LaunchAgent.copilot.acp?.arguments == ["--acp"])
        #expect(LaunchAgent.grok.acp?.arguments == ["agent", "stdio"])
        #expect(LaunchAgent.cursor.acp?.arguments == ["acp"])
    }

    @Test func everyStepHasSomethingToRun() {
        for agent in LaunchAgent.allCases {
            for step in agent.setUp {
                #expect(!step.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(agent.title): \(step.what) has nothing to run.")
            }
        }
    }
}

/// What each agent was measured doing, and what the app does with that. The point of
/// writing it down is that ACP describes the shape of a message and almost nothing about
/// the behaviour behind it. (T373.)
struct AgentProfileTests {
    @Test func aStoppedCursorAgentIsNotOfferedAStartItCannotDo() {
        // It declares loadSession and then refuses session/load, so the capability flag
        // is no help and the profile is.
        #expect(LaunchAgent.cursor.profile.resuming == .no)
        #expect(LaunchAgent.cursor.profile.resuming.canStart == false)
        var agent = Agent(projectID: "p")
        agent.launchedWith = LaunchAgent.cursor.rawValue
        agent.pid = 1
        agent.pidStartedAt = Date(timeIntervalSince1970: 1)
        #expect(agent.hasExited, "A pid from 1970 is not running.")
        #expect(Agents.mayResume(agent) == false)
        #expect(Agents.whyNoResume(agent)?.contains("Cursor cannot pick a conversation back up") == true)
    }

    @Test func theOthersAreOfferedOne() {
        for kind in [LaunchAgent.claudeCode, .copilot, .grok] {
            var agent = Agent(projectID: "p")
            agent.launchedWith = kind.rawValue
            agent.pid = 1
            agent.pidStartedAt = Date(timeIntervalSince1970: 1)
            #expect(Agents.mayResume(agent), "\(kind.title) should be startable.")
            #expect(Agents.whyNoResume(agent) == nil)
        }
    }

    @Test func anAgentThatHasNotStoppedIsNotExplainedAway() {
        var agent = Agent(projectID: "p")
        agent.launchedWith = LaunchAgent.cursor.rawValue
        // No pid at all: not seen is not dead, so there is nothing to say either way.
        #expect(Agents.mayResume(agent) == false)
        #expect(Agents.whyNoResume(agent) == nil)
    }

    @Test func twoOfThemLoseSomethingIfYouTalkOverThem() {
        // The measured reason the daemon never prompts an agent mid-turn. Half of them
        // are fine with it and half are not, which is the worst possible split: it would
        // have worked every time it was tried by hand.
        #expect(LaunchAgent.claudeCode.profile.whenBusy == .queues)
        #expect(LaunchAgent.grok.profile.whenBusy == .queues)
        #expect(LaunchAgent.copilot.profile.whenBusy == .dropsIt)
        #expect(LaunchAgent.cursor.profile.whenBusy == .cancelsItsWork)
        #expect(LaunchAgent.claudeCode.profile.whenBusy.losesSomething == false)
        #expect(LaunchAgent.grok.profile.whenBusy.losesSomething == false)
        #expect(LaunchAgent.copilot.profile.whenBusy.losesSomething)
        #expect(LaunchAgent.cursor.profile.whenBusy.losesSomething)
    }

    @Test func oneOfThemNeverAsksBeforeItActs() {
        // Grok wrote a file without asking, so a permission request will never reach the
        // person for one of its agents. Worth knowing before you pick it for something
        // that touches a repo you care about.
        #expect(LaunchAgent.grok.profile.asksFirst == .no)
        #expect(LaunchAgent.claudeCode.profile.asksFirst == .yes)
        #expect(LaunchAgent.copilot.profile.asksFirst == .yes)
    }

    @Test func oneOfThemDoesNotSayWhatKindOfToolItIsRunning() {
        // Grok's tool calls carry a name and no kind, so `changesAnything` never speaks
        // for it and its rows fall back to what it called the tool.
        #expect(LaunchAgent.grok.profile.namesToolKinds == .no)
        #expect(LaunchAgent.claudeCode.profile.namesToolKinds == .yes)
        #expect(LaunchAgent.copilot.profile.namesToolKinds == .yes)
    }

    @Test func notTriedIsItsOwnAnswerAndNotNo() {
        // Writing "not tried" down as "no" would quietly take a feature away from an
        // agent that has it.
        #expect(LaunchAgent.cursor.profile.asksFirst == .untested)
        #expect(LaunchAgent.cursor.profile.asksFirst != .no)
        #expect(AgentProfile.Known.untested.word == "Not tried")
    }

    @Test func theOnesWithSomethingToWarnAboutSayIt() {
        #expect(LaunchAgent.claudeCode.profile.caveat == nil)
        #expect(LaunchAgent.copilot.profile.caveat == nil)
        for kind in [LaunchAgent.grok, .cursor] {
            #expect(kind.profile.caveat?.isEmpty == false, "\(kind.title) has a caveat to give.")
        }
    }

    @Test func everyProfileIsAboutItsOwnAgent() {
        for kind in LaunchAgent.allCases {
            #expect(kind.profile.agent == kind)
        }
    }
}

/// How much an agent may do without asking. Before ACP every agent was launched with its
/// own auto-approve flag, because there was nobody to ask; this is what replaced them.
struct PermissionStanceTests {
    @Test func theDefaultIsWhatTheFactoryAlreadyDid() {
        #expect(Throttle.default.permissions == .allowEverything)
        #expect(Throttle().permissions == .allowEverything)
    }

    @Test func aThrottleWrittenBeforeThisKeepsGettingOnWithIt() throws {
        // An older throttle.json has no permissions field, and must not suddenly start
        // asking about everything.
        let old = Data(#"{"compileSlots":3,"simulatorSlots":2,"agentSlots":6,"swapCeiling":0.5,"memoryFloor":0.2}"#.utf8)
        let read = try JSONDecoder().decode(Throttle.self, from: old)
        #expect(read.permissions == .allowEverything)
        #expect(read.agentSlots == 6, "And it keeps everything it did say.")
    }

    @Test func lettingThemGetOnWithItAllowsTheLot() {
        for kind in [ACP.ToolCall.Kind.read, .edit, .delete, .execute, .other] {
            #expect(Throttle.Permissions.allowEverything.allows(kind))
        }
        #expect(Throttle.Permissions.allowEverything.allows(nil))
    }

    @Test func askingAboutEverythingAllowsNothing() {
        for kind in [ACP.ToolCall.Kind.read, .search, .edit, .execute] {
            #expect(Throttle.Permissions.askAboutEverything.allows(kind) == false)
        }
    }

    @Test func askingAboutChangesLetsLookingThrough() {
        let stance = Throttle.Permissions.askAboutChanges
        #expect(stance.allows(.read))
        #expect(stance.allows(.search))
        #expect(stance.allows(.fetch))
        #expect(stance.allows(.edit) == false)
        #expect(stance.allows(.delete) == false)
        #expect(stance.allows(.execute) == false)
        // Grok says nothing about what kind of call it is, and an unknown call is
        // treated as one that changes something.
        #expect(stance.allows(nil) == false)
        #expect(stance.allows(.other) == false)
    }

    @Test func everyStanceSaysWhatItMeans() {
        for stance in Throttle.Permissions.allCases {
            #expect(!stance.title.isEmpty)
            #expect(!stance.detail.isEmpty)
        }
    }
}

/// What a tool call's row actually says. Taken from what the four agents really send,
/// which is not one thing. (Alex, 16 Sep 2026.)
struct ToolHeadingTests {
    private func call(_ title: String?, kind: ACP.ToolCall.Kind? = nil, at path: String? = nil) -> ACP.ToolCall {
        ACP.ToolCall(toolCallID: "t", title: title, kind: kind,
                     locations: path.map { [ACP.Location(path: $0)] })
    }

    @Test func aTitleWrittenForAPersonIsLeftAlone() {
        #expect(call("Read README.md").heading == "Read README.md")
        #expect(call("Search tools: \"task_\"").heading == "Search tools: \"task_\"")
        #expect(call("Create file").heading == "Create file")
    }

    @Test func aBareToolNameBecomesASentence() {
        // Grok sends these and nothing else, because its calls carry no kind either.
        #expect(call("read_file", at: "/Users/alex/Projects/Demo/README.md").heading == "Reading README.md")
        #expect(call("write", at: "/a/b/notes.md").heading == "Editing notes.md")
        #expect(call("search_tool").heading == "Searching")
        #expect(call("apply_patch").heading == "Editing")
        #expect(call("bash").heading == "Running")
    }

    @Test func aToolNameNobodyNamedIsStillReadable() {
        #expect(call("fetch_the_thing").heading == "Fetch the thing")
        #expect(call("frobnicate").heading == "Frobnicate")
    }

    @Test func aLongPathInATitleIsCutDownToTheFile() {
        // Grok writes the whole path, and a row has space for about a third of it, all of
        // it the part that is the same every time.
        #expect(call("Read `/Users/alexcollins/.grok/installed-plugins/software-factory/skills/work/SKILL.md`").heading
                == "Read `SKILL.md`")
        #expect(call("Viewing /private/tmp/claude-501/-Users-alexcollins-SoftwareFactory/work/hello.txt").heading
                == "Viewing hello.txt")
        // Short ones are left as they are: the path is the information.
        #expect(call("Read src/main.swift").heading == "Read src/main.swift")
    }

    @Test func nothingAtAllStillSaysSomething() {
        #expect(call(nil, kind: .read).heading == "Reading")
        #expect(call(nil).heading == "Working")
        #expect(call("").heading == "Working")
        #expect(call(nil, kind: .execute, at: "/a/b/Makefile").heading == "Running Makefile")
    }

    @Test func theRecordingsAllComeOutReadable() throws {
        for lines in [ACPTests.recording, ACPClaudeTranscriptTests.recording] {
            for entry in ACPTranscript.folding(lines).entries {
                guard let call = entry.tool else { continue }
                let heading = call.heading
                #expect(!heading.isEmpty)
                #expect(heading.count < 60, "Too long for a row: \(heading)")
                #expect(!heading.contains("/private/"), "Still a path: \(heading)")
            }
        }
    }
}

/// An agent reached at its own address. The factory hands each ACP agent
/// `/mcp/<its id>` at `session/new`, so it never has to say who it is. (T373.)
struct OwnAddressTests {
    static func store() throws -> FileStore {
        let root = URL.temporaryDirectory.appending(path: "own-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try FileStore(root: root)
    }

    @Test func eachAgentIsHandedItsOwnAddress() {
        let agent = UUID()
        let mine = ACP.factoryServer(agent: agent)
        #expect(mine["url"] as? String == "http://127.0.0.1:4747/mcp/\(agent.uuidString)")
        // An external agent has no address of its own and passes the session as before.
        #expect(ACP.factoryServer()["url"] as? String == "http://127.0.0.1:4747/mcp")
    }

    @Test func atItsOwnAddressNoToolAsksWhoItIs() throws {
        let store = try Self.store()
        let server = MCPServer(store: store)
        let listed = try #require(server.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], as: UUID().uuidString))
        let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(!tools.isEmpty)
        for tool in tools {
            let schema = tool["inputSchema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any]
            let required = schema?["required"] as? [String] ?? []
            #expect(properties?["session_id"] == nil, "\(tool["name"] ?? "?") still asks who it is.")
            #expect(!required.contains("session_id"))
        }
    }

    @Test func atThePlainAddressEveryToolStillAsks() throws {
        let store = try Self.store()
        let server = MCPServer(store: store)
        let listed = try #require(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for tool in tools {
            let required = (tool["inputSchema"] as? [String: Any])?["required"] as? [String] ?? []
            #expect(required.contains("session_id"), "\(tool["name"] ?? "?") has to ask an external agent.")
        }
    }

    @Test func aCallFromItsOwnAddressIsSignedForIt() throws {
        let store = try Self.store()
        let project = Project(name: "Demo")
        try store.save(project)
        var agent = Agent(projectID: project.id)
        agent.number = 7
        try store.save(agent)
        let server = MCPServer(store: store)

        // No session_id anywhere in the call, and the answer is about this agent's own
        // tasks, which is the thing that needed to know.
        let answered = try #require(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "task_list", "arguments": ["project": "Demo", "mine": true]],
        ], as: agent.id.uuidString))
        let result = try #require(answered["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
    }

    /// Every agent can raise a question; nobody with a pipe of its own is offered a way to
    /// sit and wait for the answer. Raising was withheld from Claude Code until an agent
    /// was measured asking inside its own CLI instead, where the question reaches nobody
    /// who is not watching that one agent. (T373, then T422.)
    @Test func everyAgentCanRaiseAndOnlyTheOnesWithoutAPipeMayWait() {
        let asking = MCPServer.Tool.all(asking: true).map(\.name)
        #expect(asking.contains("escalation_raise"))
        #expect(!asking.contains("escalation_await"), "Raise and carry on; the task blocks itself.")
        #expect(asking.contains("escalation_list"), "It can still read what it asked.")
        let rest = MCPServer.Tool.all(asking: false).map(\.name)
        #expect(rest.contains("escalation_raise"))
        #expect(rest.contains("escalation_await"))
    }

    /// The words every agent starts with say where a question goes, because an agent that
    /// has the tool and does not know to prefer it will still ask its own interface.
    @Test func theWordsSayToRaiseRatherThanToWait() {
        let named = LaunchPrompt.project(Project(name: "Demo"), as: "A7")
        #expect(named.contains("escalation_raise"))
        #expect(named.contains("carry on with something else"))
    }

    @Test func theWordsStopTellingAnAgentAnIdItNeverUses() {
        let project = Project(name: "Demo")
        let named = LaunchPrompt.project(project, as: "A7")
        #expect(named.contains("You are agent \"A7\""))
        #expect(!named.contains("session_id"))
        #expect(named.contains("Demo"))
        // An agent in a terminal still gets told, because it calls the plain address.
        let told = LaunchPrompt.project(project, as: "A7", session: UUID())
        #expect(told.contains("session_id"))
    }
}

/// Putting an agent into a mode where it does not have to ask. (Alex, 16 Sep 2026.)
struct SessionModeTests {
    /// What Claude Code really offers, from its `session/new` answer.
    static let claudeOffers = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]

    @Test func theModesComeOffTheAnswer() {
        let answer: [String: Any] = ["modes": [
            "currentModeId": "default",
            "availableModes": [["id": "default"], ["id": "bypassPermissions"]],
        ]]
        #expect(ACP.Modes.offered(in: answer) == ["default", "bypassPermissions"])
        #expect(ACP.Modes.current(in: answer) == "default")
        #expect(ACP.Modes.offered(in: [:]).isEmpty)
        #expect(ACP.Modes.current(in: [:]) == nil)
    }

    @Test func gettingOnWithItTakesTheMostPermissiveOnOffer() {
        #expect(ACP.Modes.wanted(.allowEverything, from: Self.claudeOffers) == "bypassPermissions")
        // Without the best one, the next best.
        #expect(ACP.Modes.wanted(.allowEverything, from: ["default", "acceptEdits"]) == "acceptEdits")
        #expect(ACP.Modes.wanted(.allowEverything, from: ["default", "auto"]) == "auto")
    }

    @Test func askingPutsItBackIntoAsking() {
        #expect(ACP.Modes.wanted(.askAboutChanges, from: Self.claudeOffers) == "default")
        #expect(ACP.Modes.wanted(.askAboutEverything, from: Self.claudeOffers) == "default")
    }

    @Test func anAgentWithNothingUsefulToOfferIsLeftAlone() {
        // Copilot's modes are about how it converses, and Grok has none at all. For those
        // the factory answers their requests quickly instead.
        let copilot = ["https://agentclientprotocol.com/protocol/session-modes#agent"]
        #expect(ACP.Modes.wanted(.allowEverything, from: copilot) == nil)
        #expect(ACP.Modes.wanted(.allowEverything, from: []) == nil)
        #expect(ACP.Modes.wanted(.askAboutEverything, from: []) == nil)
    }

    @Test func theRequestIsTheShapeTheWireWants() {
        let asked = ACP.setMode("bypassPermissions", session: "s1")
        #expect(asked["sessionId"] as? String == "s1")
        #expect(asked["modeId"] as? String == "bypassPermissions")
    }
}

/// Letting the agent judge for itself, which is not the same as being told yes.
/// (Alex, 16 Sep 2026.)
struct AgentDecidesTests {
    static let claudeOffers = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]

    @Test func itTakesTheModeWhereTheAgentJudges() {
        // `auto` is "Claude handles permission decisions". `bypassPermissions` is
        // "Accepts all permissions". They are different things and it matters which.
        #expect(ACP.Modes.wanted(.agentDecides, from: Self.claudeOffers) == "auto")
        #expect(ACP.Modes.wanted(.allowEverything, from: Self.claudeOffers) == "bypassPermissions")
    }

    @Test func withoutAnAutoModeItTakesTheNextNearestThing() {
        #expect(ACP.Modes.wanted(.agentDecides, from: ["default", "acceptEdits"]) == "acceptEdits")
        // And with nothing at all, the factory says yes on its behalf rather than
        // stopping it, which is the nearest thing to letting it judge.
        #expect(ACP.Modes.wanted(.agentDecides, from: []) == nil)
        #expect(Throttle.Permissions.agentDecides.allows(.edit))
        #expect(Throttle.Permissions.agentDecides.allows(.execute))
    }

    @Test func itIsOfferedAsAChoiceLikeTheRest() {
        #expect(Throttle.Permissions.allCases.contains(.agentDecides))
        #expect(Throttle.Permissions.agentDecides.title == "Let each agent decide")
        #expect(!Throttle.Permissions.agentDecides.detail.isEmpty)
    }

    @Test func aThrottleWithAnUnknownStanceStillGetsOnWithIt() throws {
        // A throttle written by a later version, read by this one.
        let later = Data(#"{"compileSlots":5,"simulatorSlots":4,"agentSlots":8,"swapCeiling":0.75,"memoryFloor":0.15,"permissions":"somethingNew"}"#.utf8)
        let read = try JSONDecoder().decode(Throttle.self, from: later)
        #expect(read.permissions == .allowEverything)
    }

    @Test func theModesComeBackWithTheWordsTheAgentUsesForThem() {
        let answer: [String: Any] = ["modes": [
            "currentModeId": "default",
            "availableModes": [
                ["id": "default", "name": "Manual", "description": "Always ask before making changes"],
                ["id": "auto", "name": "Auto", "description": "Claude handles permission decisions"],
            ],
        ]]
        let listed = ACP.Modes.listed(in: answer)
        #expect(listed.map(\.id) == ["default", "auto"])
        #expect(listed.map(\.name) == ["Manual", "Auto"])
        #expect(listed[1].detail == "Claude handles permission decisions")
        // An agent that offers none gets no menu at all, which is Grok.
        #expect(ACP.Modes.listed(in: [:]).isEmpty)
    }
}

/// The mode the agent is in, as opposed to the one we asked for. (T426.)
@Suite struct ModeUpdateTests {
    @Test func aModeUpdateIsReadRatherThanDropped() {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"current_mode_update","currentModeId":"bypassPermissions"}}}"#
        guard case .update(let session, let update) = ACP.read(line: line) else {
            Issue.record("not an update"); return
        }
        #expect(session == "s1")
        #expect(update == .mode("bypassPermissions"))
    }

    /// It is state rather than something said, so no page of the conversation draws it.
    @Test func itIsNotSomethingTheConversationShows() {
        var transcript = ACPTranscript()
        transcript.apply(.mode("default"))
        #expect(transcript.entries.isEmpty)
        var headline = ACPHeadline()
        headline.apply(.message(.text("Reading Models.swift")))
        headline.apply(.mode("default"))
        #expect(headline.line == "Reading Models.swift")
    }

    /// An update we have never seen still goes through as itself, so the raw log stays
    /// honest and nothing crashes on a word a later version invents.
    @Test func anUnknownUpdateIsStillCarried() {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"something_new"}}}"#
        guard case .update(_, let update) = ACP.read(line: line) else {
            Issue.record("not an update"); return
        }
        #expect(update == .other("something_new"))
    }
}

/// What a person can hand an agent, and what happens when that agent cannot take it.
/// The capabilities are per agent and were measured rather than read. (T427, T428.)
@Suite struct AttachmentTests {
    private let picture = ACP.Attachment.image(data: Data([0x89, 0x50]), mimeType: "image/png",
                                               name: "screenshot.png")
    private let file = ACP.Attachment.words(path: "/tmp/notes.md", text: "The plan.",
                                            name: "notes.md")

    @Test func whatAnAgentTakesIsReadOffItsHandshake() {
        let claude: [String: Any] = ["agentCapabilities": ["promptCapabilities": ["image": true, "embeddedContext": true]]]
        #expect(ACP.Attachments.read(claude) == ACP.Attachments(image: true, embeddedContext: true))
        let grok: [String: Any] = ["agentCapabilities": ["promptCapabilities": ["image": false, "embeddedContext": true]]]
        #expect(ACP.Attachments.read(grok) == ACP.Attachments(image: false, embeddedContext: true))
        // An agent that says nothing takes nothing but words.
        #expect(ACP.Attachments.read([:]) == ACP.Attachments())
    }

    @Test func aPictureGoesAsAPicture() throws {
        let (block, refusal) = ACP.block(for: picture, takes: .init(image: true))
        let sent = try #require(block)
        #expect(refusal == nil)
        #expect(sent["type"] as? String == "image")
        #expect(sent["mimeType"] as? String == "image/png")
        #expect(sent["data"] as? String == Data([0x89, 0x50]).base64EncodedString())
    }

    /// Grok takes no image. There is no honest smaller version of a screenshot, so it is
    /// refused in words rather than sent as a filename.
    @Test func anAgentThatCannotSeeIsToldSoRatherThanSentAName() {
        let (block, refusal) = ACP.block(for: picture, takes: .init(image: false))
        #expect(block == nil)
        #expect(refusal?.contains("screenshot.png") == true)
    }

    @Test func aFileOfWordsGoesAsAResourceWhereItCan() throws {
        let (block, refusal) = ACP.block(for: file, takes: .init(embeddedContext: true))
        let sent = try #require(block)
        #expect(refusal == nil)
        #expect(sent["type"] as? String == "resource")
        let resource = try #require(sent["resource"] as? [String: Any])
        #expect(resource["uri"] as? String == "file:///tmp/notes.md")
        #expect(resource["text"] as? String == "The plan.")
    }

    /// Cursor takes no embedded resource, and every agent takes text, so the file goes in
    /// as text with its name on it rather than not at all.
    @Test func aFileOfWordsDegradesToWords() throws {
        let (block, refusal) = ACP.block(for: file, takes: .init(embeddedContext: false))
        let sent = try #require(block)
        #expect(refusal == nil)
        #expect(sent["type"] as? String == "text")
        #expect((sent["text"] as? String)?.contains("notes.md") == true)
        #expect((sent["text"] as? String)?.contains("The plan.") == true)
    }

    @Test func theWordsComeFirstAndTheAttachmentsFollow() throws {
        let (block, _) = ACP.block(for: picture, takes: .init(image: true))
        let sent = ACP.prompt("What is wrong with this?", attaching: [block!], session: "s1")
        let prompt = try #require(sent["prompt"] as? [[String: Any]])
        #expect(prompt.count == 2)
        #expect(prompt[0]["type"] as? String == "text")
        #expect(prompt[1]["type"] as? String == "image")
        // Nothing said, one thing attached: still a prompt, with no empty line in front.
        let bare = ACP.prompt("", attaching: [block!], session: "s1")
        #expect((bare["prompt"] as? [[String: Any]])?.count == 1)
    }
}

/// What to say when an agent will not start. (T435, off the handshakes in T428.)
@Suite struct WayInTests {
    /// Copilot hands over the command to run, in its own handshake.
    @Test func theCommandIsReadWhereTheAgentGivesOne() throws {
        let hello: [String: Any] = ["authMethods": [[
            "id": "copilot-login", "name": "Log in with Copilot CLI",
            "description": "Run `copilot login` in the terminal",
            "_meta": ["terminal-auth": ["command": "/opt/homebrew/bin/copilot", "args": ["login"]]],
        ]]]
        let ways = ACP.WayIn.read(hello)
        #expect(ways.count == 1)
        #expect(ways[0].command == "/opt/homebrew/bin/copilot login")
        let why = ACP.whyItWouldNotStart("it made no session", kind: "GitHub Copilot", ways: ways)
        #expect(why.contains("logged in"))
        #expect(why.contains("/opt/homebrew/bin/copilot login"))
    }

    /// Cursor describes it in words instead, so the words are what is said.
    @Test func theDescriptionStandsInWhereThereIsNoCommand() {
        let hello: [String: Any] = ["authMethods": [[
            "id": "cursor_login", "name": "Cursor Login",
            "description": "Authenticate using existing Cursor login credentials. Run 'agent login' first if not logged in.",
        ]]]
        let why = ACP.whyItWouldNotStart("it made no session", kind: "Cursor", ways: ACP.WayIn.read(hello))
        #expect(why.contains("agent login"))
    }

    /// Claude Code declares no way in, so a failure there is some other failure and this
    /// must not claim otherwise.
    @Test func anAgentWithNoWayInKeepsItsOwnError() {
        let why = ACP.whyItWouldNotStart("claude-agent-acp is not on this Mac.",
                                          kind: "Claude Code", ways: ACP.WayIn.read([:]))
        #expect(why == "claude-agent-acp is not on this Mac.")
    }
}

/// What an agent can be asked to do. Read off a real line: this one was recorded from
/// this factory's own transcripts. (T436.)
@Suite struct AvailableCommandTests {
    @Test func commandsAreReadRatherThanDropped() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"ship-it","description":"Ship an Xcode app end to end. Use whenever Alex says ship it."},{"name":"init"}]}}}"#
        guard case .update(_, let update) = ACP.read(line: line), case .commands(let listed) = update else {
            Issue.record("not commands"); return
        }
        #expect(listed.map(\.name) == ["ship-it", "init"])
        #expect(listed[0].typed == "/ship-it ")
        // A description runs to a paragraph, and a menu row holds a sentence.
        #expect(listed[0].brief == "Ship an Xcode app end to end")
        #expect(listed[1].brief == nil)
    }
}
