import Foundation
import Testing
@testable import SoftwareFactoryKit

/// The agent asking the person a question. `Fixtures/elicitation.json` is a real one from
/// `claude-agent-acp`, captured by asking it to choose between two names, and answered
/// with "Beta" over the wire: it replied "Beta." and stopped. (T373, 16 Sep 2026.)
struct ACPElicitationTests {
    static var real: [String: Any] {
        guard let url = Bundle.module.url(forResource: "elicitation", withExtension: "json",
                                          subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return body
    }

    @Test func aRealOneReadsAsAQuestionWithChoices() throws {
        let asked = try #require(ACP.Elicitation.read(Self.real))
        #expect(asked.message == "Should this project be called Alpha or Beta?")
        #expect(asked.about == "Name")
        #expect(asked.field == "question_0")
        #expect(asked.options.map(\.title) == ["Alpha", "Beta"])
        #expect(asked.options[0].detail.hasPrefix("Signals this is the first cut"))
        // The free-text companion, found by its shared `_meta` marker rather than by its
        // name, which belongs to the agent.
        #expect(asked.customField == "question_0_custom")
        #expect(asked.toolCallID?.hasPrefix("toolu_") == true)
    }

    @Test func itBecomesAnOrdinaryQuestionOnTheFloor() throws {
        let asked = try #require(ACP.Elicitation.read(Self.real))
        let agent = UUID()
        let question = asked.asEscalation(projectID: "p1", agentID: agent, raisedBy: "A7",
                                          reference: "acp-question:x")
        #expect(question.question == "Should this project be called Alpha or Beta?")
        #expect(question.options.map(\.title) == ["Alpha", "Beta"])
        #expect(question.options[1].detail.contains("ready for people to try"))
        #expect(question.agentID == agent)
        #expect(question.raisedBy == "A7")
        #expect(question.reference == "acp-question:x")
        #expect(question.isOpen)
    }

    @Test func pickingAnOptionGoesBackInTheShapeItWasAskedIn() throws {
        let asked = try #require(ACP.Elicitation.read(Self.real))
        let answer = asked.answer(option: "Beta")
        #expect(answer["action"] as? String == "accept")
        let content = try #require(answer["content"] as? [String: Any])
        #expect(content["question_0"] as? String == "Beta")
        #expect(content["question_0_custom"] == nil)
    }

    @Test func answeringInYourOwnWordsUsesTheFieldItOffered() throws {
        let asked = try #require(ACP.Elicitation.read(Self.real))
        let content = try #require(asked.answer(option: nil, words: "Call it Fingerpost.")["content"] as? [String: Any])
        #expect(content["question_0_custom"] as? String == "Call it Fingerpost.")
        // An option and a note together, which is what a decision with a note is.
        let both = try #require(asked.answer(option: "Alpha", words: "for now")["content"] as? [String: Any])
        #expect(both["question_0"] as? String == "Alpha")
        #expect(both["question_0_custom"] as? String == "for now")
    }

    @Test func wordsWithNowhereToPutThemGoUnderTheOption() {
        let plain = ACP.Elicitation(
            sessionID: "s", message: "Which?", field: "q",
            options: [.init(value: "a", title: "A")])
        let content = plain.answer(option: nil, words: "Neither, do the other thing.")["content"] as? [String: Any]
        #expect(content?["q"] as? String == "Neither, do the other thing.")
    }

    @Test func answeringNothingDeclinesRatherThanSendingAnEmptyForm() throws {
        let asked = try #require(ACP.Elicitation.read(Self.real))
        #expect(asked.answer(option: nil, words: "   ")["action"] as? String == "decline")
        #expect(asked.declined["action"] as? String == "decline")
    }

    @Test func aFormWithNothingToChooseIsRefusedRatherThanShown() {
        // A question with no answers on it is worse than no question.
        #expect(ACP.Elicitation.read([
            "sessionId": "s", "mode": "form", "message": "Anything?",
            "requestedSchema": ["type": "object", "properties": ["note": ["type": "string"]]],
        ]) == nil)
        #expect(ACP.Elicitation.read(["sessionId": "s", "mode": "form", "message": "x"]) == nil)
    }

    @Test func aUrlModeRequestIsNotOneWeCanShow() {
        #expect(ACP.Elicitation.read([
            "sessionId": "s", "mode": "url", "url": "https://example.com/oauth",
            "elicitationId": "e1",
        ]) == nil)
    }

    @Test func aMultiSelectFormIsReadTheSameWay() throws {
        let asked = try #require(ACP.Elicitation.read([
            "sessionId": "s", "mode": "form", "message": "Which ones?",
            "requestedSchema": ["type": "object", "properties": [
                "question_0": ["type": "array", "title": "Pick",
                               "items": ["anyOf": [["const": "a", "title": "A"], ["const": "b", "title": "B"]]]],
            ]],
        ]))
        #expect(asked.options.map(\.value) == ["a", "b"])
    }

    @Test func aWholeLineComesOffTheWire() throws {
        let line = #"{"jsonrpc":"2.0","id":9,"method":"elicitation/create","params":{"mode":"form","sessionId":"s","message":"Ship it?","requestedSchema":{"type":"object","properties":{"question_0":{"type":"string","oneOf":[{"const":"Yes","title":"Yes"},{"const":"No","title":"No"}]}}}}}"#
        guard case .question(let id, let asked) = ACP.read(line: line) else {
            Issue.record("An elicitation has to come off the wire as a question.")
            return
        }
        #expect(id == 9)
        #expect(asked.message == "Ship it?")
        #expect(asked.options.count == 2)
    }

    @Test func theFactoryTellsAgentsItCanShowAForm() {
        // Claude Code's adapter switches its own question tool off unless a client says
        // it can show a form, so not declaring this made the factory the reason it could
        // not ask.
        let caps = ACP.clientCapabilities
        let elicitation = caps["elicitation"] as? [String: Any]
        #expect(elicitation?["form"] != nil)
        #expect(caps["terminal"] as? Bool == false)
    }
}

/// Which agents actually ask. Measured by declaring the capability and telling each one
/// to put a choice to the person. (16 Sep 2026.)
struct AsksThroughTheProtocolTests {
    @Test func onlyClaudeCodeDoes() {
        #expect(LaunchAgent.claudeCode.profile.asksThroughTheProtocol == .yes)
        // Copilot and Grok write the question as prose and end the turn, which is a
        // question the floor cannot see. `escalation_raise` is how they ask.
        #expect(LaunchAgent.copilot.profile.asksThroughTheProtocol == .no)
        #expect(LaunchAgent.grok.profile.asksThroughTheProtocol == .no)
    }

    @Test func soTheOldWayOfAskingIsNotGoing() {
        // Three of four need it, and an external agent has no pipe at all.
        #expect(MCPServer.Tool.all.contains { $0.name == "escalation_raise" })
        #expect(MCPServer.Tool.all.contains { $0.name == "escalation_await" })
    }
}
