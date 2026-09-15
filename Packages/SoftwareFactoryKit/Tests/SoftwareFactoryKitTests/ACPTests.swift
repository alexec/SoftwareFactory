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
        // Claude Code speaks it through an adapter you install; Copilot has it built in
        // and so has nothing to set up beyond Copilot itself.
        #expect(LaunchAgent.claudeCode.setUp.map(\.what) == ["The part that speaks ACP"])
        #expect(LaunchAgent.copilot.setUp.isEmpty)
    }

    @Test func oneThatDoesNotSpeakItStillRegistersTheOldWay() {
        for agent in LaunchAgent.allCases where !agent.speaksACP && agent.isCodingAgent {
            #expect(agent.setUp.contains { $0.what.contains("Register") })
            #expect(agent.installURL != nil)
        }
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
