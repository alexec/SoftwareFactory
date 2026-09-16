import AppKit
import SwiftUI
import SoftwareFactoryKit

/// How to set up each agent the factory can start: what it is, where to get it, and the
/// one command to run before it will work.
///
/// This used to sit inside the launch popover, under the picker, and it was read and
/// dismissed every single time anybody started an agent. Setting up an agent happens once
/// and launching one happens all day, so the instructions live here and the popover links
/// to them. It is a window of the app's own, opened from the Help menu the way help is
/// opened on a Mac, so it can be left open beside a terminal while you follow it.
/// (Alex, 16 Sep 2026.)
struct AgentSetupHelp: View {
    /// The window this opens in, so the Help menu and the link both land in one place.
    static let windowID = "agent-setup-help"
    static let title = "Setting up agents"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("The factory starts an agent in the project's folder, in your own environment. It does not install anything for you, so each one is set up once, here, and then it is there every time you launch it.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(LaunchAgent.allCases) { agent in
                    AgentSetup(agent: agent)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Why each one has a note")
                        .font(.headline)
                    Text("ACP says what a message looks like and almost nothing about the behaviour behind it. All four of these are conformant and all four disagree, so the factory keeps its own notes from driving each one rather than from reading its documentation. Not tried means exactly that, and is not the same as no.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Two ways an agent runs")
                        .font(.headline)
                    Text("Claude Code and GitHub Copilot speak ACP, a protocol for coding agents. The factory hands them their tools as they start, and their page shows the work itself: what they are reading, what they are changing, and the plan they are following. They are held by a daemon of their own, so they keep working while this app is rebuilt.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Grok and Cursor do not speak it yet, so they run in a terminal on their page, which you can also type into by hand. Both kinds work the same way everywhere else: the same backlog, the same questions, the same nudges.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
            }
            .padding(Style.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.paper))
        .tint(Color(.mark))
        .frame(minWidth: 460, idealWidth: 560, minHeight: 420, idealHeight: 620)
    }
}

/// One agent: what it is, where to get it, and what to run.
private struct AgentSetup: View {
    var agent: LaunchAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(agent.title)
                .font(.headline)
            Text(agent.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let installURL = agent.installURL {
                Link(destination: installURL) {
                    Label("How to install \(agent.title)", systemImage: "arrow.up.right.square")
                }
                .font(.callout)
            }
            ForEach(Array(agent.setUp.enumerated()), id: \.offset) { _, step in
                CommandToRun(what: step.what, command: step.command)
            }
            WhatItDoes(profile: agent.profile)
            if let caveat = agent.profile.caveat {
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Style.cardPadding)
        .background(.quinary, in: .rect(cornerRadius: Style.card))
    }
}

/// What this agent was measured doing, as opposed to what it says it can do.
private struct WhatItDoes: View {
    var profile: AgentProfile

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            row("Can be started back up", profile.resuming.word)
            row("Asks before it changes something", profile.asksFirst.word)
            row("Says what it is thinking", profile.thinksOutLoud.word)
            row("Sets out a plan", profile.plans.word)
            row("Says what kind of tool it is running", profile.namesToolKinds.word)
            row("Puts questions to you through the factory", profile.asksThroughTheProtocol.word)
            row("If you talk over it", profile.whenBusy.word)
        }
        .font(.callout)
        .padding(.top, 2)
    }

    private func row(_ what: String, _ answer: String) -> some View {
        GridRow {
            Text(what).foregroundStyle(.secondary)
            Text(answer)
        }
    }
}

/// A line to paste into a terminal, with a button that copies it.
private struct CommandToRun: View {
    var what: String
    var command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(what)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy") {
                    AgentLauncher.copyCommand(command)
                    copied = true
                }
                .controlSize(.small)
            }
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: Style.panel))
        }
    }
}
