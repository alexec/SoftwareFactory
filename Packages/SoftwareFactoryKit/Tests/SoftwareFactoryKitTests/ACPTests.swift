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

    @Test func anUpdateWeDoNotDrawIsKeptRatherThanDropped() {
        let kinds = Self.recording.compactMap { line -> String? in
            guard case .update(_, .other(let kind)) = ACP.read(line: line) else { return nil }
            return kind
        }
        #expect(kinds.contains("available_commands_update"))
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

    @Test func aShellNeedsNothingSettingUp() {
        #expect(LaunchAgent.terminal.setUp.isEmpty)
        #expect(LaunchAgent.terminal.installURL == nil)
        #expect(LaunchAgent.terminal.isCodingAgent == false)
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

    @Test func everyAgentSpeaksItAndOnlyTheShellDoesNot() {
        // Checked by handshaking with each binary rather than by grepping its help,
        // which found two and missed the two that put it behind a subcommand.
        for agent in LaunchAgent.allCases where agent.isCodingAgent {
            #expect(agent.speaksACP, "\(agent.title) has to speak ACP.")
            #expect(agent.installURL != nil)
        }
        #expect(LaunchAgent.terminal.speaksACP == false)
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
        for kind in [LaunchAgent.grok, .cursor, .terminal] {
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
