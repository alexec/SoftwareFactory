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

    @Test func everyKindHasATitleInstallAndSetup() {
        #expect(LaunchAgent.allCases.map(\.title) == ["Claude Code", "GitHub Copilot", "Grok", "Cursor"])
        for agent in LaunchAgent.allCases {
            #expect(!agent.installURL.absoluteString.isEmpty)
            #expect(agent.installURL.scheme == "https")
            #expect(!agent.setupCommand.isEmpty)
        }
    }

    @Test func setupCommandNamesThePlugin() {
        #expect(LaunchAgent.claudeCode.setupCommand.contains("claude plugin"))
        #expect(LaunchAgent.claudeCode.setupCommand.contains("software-factory"))
        #expect(LaunchAgent.copilot.setupCommand.contains("copilot plugin install"))
        #expect(LaunchAgent.copilot.setupCommand.contains("Plugins/software-factory"))
        #expect(LaunchAgent.grok.setupCommand.contains("grok plugin install"))
        #expect(LaunchAgent.grok.setupCommand.contains("Plugins/software-factory"))
        #expect(LaunchAgent.cursor.setupCommand.contains("cursor-agent plugin marketplace add"))
        #expect(LaunchAgent.cursor.setupCommand.contains("alexec/SoftwareFactory"))
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
