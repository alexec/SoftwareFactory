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
        #expect(LaunchAgent.allCases.map(\.title) == ["Claude Code", "GitHub Copilot", "Grok"])
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
    }

    @Test func commandUsesTheAgentsBinaryAndQuotesThePrompt() {
        let words = "You're the browser owner."
        #expect(LaunchAgent.claudeCode.command(for: words, session: Self.session).hasPrefix("claude --session-id \(Self.session.uuidString) --permission-mode=auto "))
        #expect(LaunchAgent.copilot.command(for: words, session: Self.session).hasPrefix("copilot --session-id \(Self.session.uuidString) --allow-all --interactive "))
        #expect(LaunchAgent.grok.command(for: words, session: Self.session).hasPrefix("grok --session-id \(Self.session.uuidString) --always-approve --trust "))
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

    @Test func grokTrustsTheLaunchDirectory() {
        let words = "Work the backlog."
        #expect(LaunchAgent.grok.command(for: words, session: Self.session).contains(" --trust "))
        #expect(LaunchAgent.grok.resumeCommand(session: Self.session) == "grok --resume \(Self.session.uuidString) --always-approve --trust")
    }
}
