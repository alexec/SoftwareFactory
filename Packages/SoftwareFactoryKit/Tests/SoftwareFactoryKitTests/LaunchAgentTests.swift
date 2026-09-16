import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct LaunchAgentTests {
    static let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let project = Project(name: "Walkist")

    @Test func rememberedFallsBackToClaudeCode() {
        #expect(LaunchAgent.remembered(nil) == .claudeCode)
        #expect(LaunchAgent.remembered("grok") == .grok)
        #expect(LaunchAgent.remembered("nope") == .claudeCode)
    }

    @Test func everyKindHasATitleAndSomewhereToGetIt() {
        #expect(LaunchAgent.allCases.map(\.title) == ["Claude Code", "GitHub Copilot", "Grok", "Cursor"])
        for agent in LaunchAgent.allCases {
            #expect(agent.installURL?.scheme == "https")
        }
    }

    /// A shell was one of these and never was one: it registered with nothing, was told
    /// nothing, held no task and had no conversation to resume, so every question asked of
    /// this type had to be answered "except for that one". It is opened beside an agent
    /// now, which is what it was always for. (Alex, 16 Sep 2026.)
    @Test func aShellIsNotOneOfThese() {
        #expect(LaunchAgent.allCases.map(\.rawValue) == ["claudeCode", "copilot", "grok", "cursor"])
        #expect(LaunchAgent.remembered("terminal") == .claudeCode)
    }

    /// There is no registering any more. `session/new` carries the factory's MCP server,
    /// so an ACP agent is handed its tools as it starts, and all four of ours speak ACP.
    /// The plugin marketplace commands went with `setupCommand`. (T373.)
    @Test func thereIsNothingToRegisterAnyMore() {
        for agent in LaunchAgent.allCases {
            #expect(agent.setUp.contains { $0.what.lowercased().contains("register") } == false)
            #expect(agent.setUp.contains { $0.command.contains("plugin") } == false)
        }
        // The one thing still worth installing is Zed's adapter, for Claude Code.
        #expect(LaunchAgent.claudeCode.setUp.count == 1)
        for agent in [LaunchAgent.copilot, .grok, .cursor] {
            #expect(agent.setUp.isEmpty)
        }
    }

    @Test func commandUsesTheAgentsBinaryAndQuotesThePrompt() {
        let words = "You're the browser owner."
        #expect(LaunchAgent.claudeCode.command(for: words, session: Self.session).hasPrefix("claude --session-id \(Self.session.uuidString) --permission-mode=auto "))
        #expect(LaunchAgent.copilot.command(for: words, session: Self.session).hasPrefix("copilot --session-id \(Self.session.uuidString) --allow-all --interactive "))
        #expect(LaunchAgent.grok.command(for: words, session: Self.session).hasPrefix("grok --session-id \(Self.session.uuidString) --always-approve --trust "))
        #expect(LaunchAgent.cursor.command(for: words, session: Self.session).hasPrefix("cursor-agent --force --trust --approve-mcps "))
        for agent in LaunchAgent.allCases {
            #expect(agent.command(for: words, session: Self.session).contains(LaunchAgent.quoted(words)))
        }
    }

    @Test func quotedPromptSurvivesAnApostrophe() {
        #expect(LaunchAgent.quoted("it's") == "'it'\\''s'")
    }

    @Test func projectLaunchCommandCarriesThePromptWords() {
        let line = LaunchAgent.claudeCode.launchCommand(for: project, as: "A7", session: Self.session)
        #expect(line.contains("claude --session-id \(Self.session.uuidString)"))
        #expect(line.contains("A7") && line.contains(Self.session.uuidString))
        #expect(line.contains("Walkist"))
    }

    @Test func taskLaunchCommandNamesTheTask() {
        var task = FactoryTask(projectID: project.id, title: "Move the add row", rank: 1)
        task.number = 164
        let line = LaunchAgent.grok.launchCommand(for: project, task: task, as: "A16", session: Self.session)
        #expect(line.hasPrefix("grok --session-id \(Self.session.uuidString) --always-approve --trust "))
        #expect(line.contains("T164"))
        #expect(line.contains("Move the add row"))
    }

    /// Cursor makes its own chat id, so the factory's session is in the words it starts
    /// with and not on the command line, and resume is the newest chat in the folder.
    @Test func cursorCarriesTheSessionInThePromptOnly() {
        let line = LaunchAgent.cursor.launchCommand(for: project, as: "A9", session: Self.session)
        #expect(!line.contains("--session-id"))
        #expect(line.contains(Self.session.uuidString))
        #expect(line.contains("A9") && line.contains("Walkist"))
        #expect(LaunchAgent.cursor.resumeCommand(session: Self.session) == "cursor-agent --continue --force --trust --approve-mcps")
        #expect(!LaunchAgent.cursor.resumeCommand(session: Self.session).contains(Self.session.uuidString))
    }

    /// Every one of them approves its own tool calls and trusts the folder it opens in,
    /// or the agent stops on a prompt nobody is there to answer.
    @Test func everyKindStartsWithoutAskingPermission() {
        let started = LaunchAgent.allCases.map { $0.command(for: "Work the backlog.", session: Self.session) }
        #expect(started.allSatisfy { $0.contains("--permission-mode=auto") || $0.contains("--allow-all") || $0.contains("--always-approve") || $0.contains("--force") })
    }

    @Test func grokTrustsTheLaunchDirectory() {
        let words = "Work the backlog."
        #expect(LaunchAgent.grok.command(for: words, session: Self.session).contains(" --trust "))
        #expect(LaunchAgent.grok.resumeCommand(session: Self.session) == "grok --resume \(Self.session.uuidString) --always-approve --trust")
    }
}
