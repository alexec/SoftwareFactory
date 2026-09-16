import SwiftUI
import SoftwareFactoryKit

/// What an ACP agent has done, as a page. This is what replaces the terminal, and the
/// reason for the whole rebuild: the factory is told what the agent is doing, so the page
/// can say "Editing Models.swift, 12 lines" instead of showing a picture of a CLI saying
/// so. (T373.)
struct AgentTranscriptView: View {
    @Environment(Floor.self) private var floor
    var agent: Agent
    @State private var words = ""
    @State private var showsThinking = false

    private var transcript: ACPTranscript { floor.transcripts[agent.id] ?? floor.transcript(agent.id) }
    private var running: AgentDaemon.Running? { floor.running(agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            if let waiting = running?.waiting {
                PermissionBar(agent: agent, waiting: waiting)
                Divider()
            }
            if !transcript.plan.isEmpty {
                PlanBar(entries: transcript.plan)
                Divider()
            }
            page
            Divider()
            sayBox
        }
        .task(id: agent.id) {
            floor.watch(agent.id)
            await floor.look()
        }
        .onDisappear { floor.stopWatching(agent.id) }
    }

    private var page: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(shown) { row in
                        Entry(row: row).id(row.id)
                    }
                    if running?.isPrompting == true {
                        Working(queued: running?.queued ?? 0).id(Self.bottom)
                    } else {
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                }
                .padding(.horizontal, Style.page)
                .padding(.vertical, Style.page)
                // A measure: past about this width the eye loses the start of the next
                // line. It is the same one the documents are set to. (T311's paper.)
                .frame(maxWidth: Paper.measure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color(.paper))
            // The newest thing is what you came to read, the same as a terminal always
            // showed you the bottom.
            .onChange(of: shown.last?.id) { _, _ in
                withAnimation(.snappy) { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onAppear { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            .overlay { if shown.isEmpty { nothingYet } }
        }
    }

    private static let bottom = -1

    /// Thinking is off by default. It is worth having and not worth reading most of the
    /// time, and an agent's thoughts are nine tenths of the words on this page. Runs of
    /// tool calls are collapsed to their most recent by `ACPTranscript.page`.
    private var shown: [ACPTranscript.Shown] {
        transcript.page(thinking: showsThinking)
    }

    private var nothingYet: some View {
        VStack(spacing: 6) {
            Text(running?.state == .starting ? "Starting" : "Nothing yet")
                .font(.headline)
            Text(running?.state == .starting
                 ? "It is handshaking with the factory."
                 : "Say something to it below.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The field that used to be a terminal you typed into. It is `session/prompt` now,
    /// which is better, but it is the same thing: words to the agent.
    private var sayBox: some View {
        HStack(spacing: 8) {
            if transcript.entries.contains(where: { if case .thought = $0.kind { return true }; return false }) {
                Button {
                    withAnimation(.snappy) { showsThinking.toggle() }
                } label: {
                    Image(systemName: showsThinking ? "brain.filled.head.profile" : "brain.head.profile")
                }
                .buttonStyle(.borderless)
                .help(showsThinking ? "Hide what it is thinking" : "Show what it is thinking")
            }
            TextField("Say something to \(agent.label)", text: $words, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .serif))
                .onSubmit(say)
            if running?.isPrompting == true {
                Button("Stop", systemImage: "stop.fill") {
                    Task { await floor.cancel(agent.id) }
                }
                .buttonStyle(.borderless)
                .help("Stop what it is doing, without stopping the agent")
            }
            Button("Send", systemImage: "arrow.up.circle.fill", action: say)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, Style.page)
        .padding(.vertical, 10)
        .background(Color(.paper))
    }

    private func say() {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        words = ""
        // Straight to the agent, not through the mailbox. This is a person typing on the
        // agent's own page, which is what the terminal was, and the terminal never
        // queued: the mailbox and its cap of three are for messages from other agents.
        // The daemon writes it into the transcript, so it appears here either way.
        Task { await floor.say(said, to: agent.id) }
    }

    // MARK: The pieces

    private struct Entry: View {
        var row: ACPTranscript.Shown

        var body: some View {
            switch row.entry.kind {
            case .asked(let text): Asked(text: text)
            case .said(let text): Said(text: text)
            case .thought(let text): Thought(text: text)
            case .tool(let call): ToolRow(call: call, alsoRan: row.alsoRan)
            }
        }
    }

    /// What the factory or the person said. In a bubble against the leading edge, so the
    /// page reads as two people rather than as a log.
    private struct Asked: View {
        var text: String
        var body: some View {
            Text(text)
                .font(.system(.callout, design: .serif))
                .foregroundStyle(Color(.ink))
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                // Set into the page rather than sitting on it: no shadow, no gloss.
                .background(Color(.block), in: .rect(cornerRadius: Style.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: Style.panel)
                        .strokeBorder(Color(.rule), lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Said: View {
        var text: String
        var body: some View {
            MarkdownText(text: text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(Color(.ink))
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Thought: View {
        var text: String
        var body: some View {
            Text(text)
                .font(.system(.callout, design: .serif).italic())
                .foregroundStyle(Color(.quiet))
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(.rule)).frame(width: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One tool call: what it is, whether it is done, and what it changed. A card, because
    /// it is a thing that happened rather than a line in a log.
    ///
    /// Only the most recent of a run is drawn, `ACPTranscript.page`, and this says how
    /// many went before it. An agent reads four files and searches twice before it writes
    /// anything, and a dozen finished cards buried the two things worth reading: what it
    /// said, and what it is doing now. (Alex, 16 Sep 2026.)
    private struct ToolRow: View {
        var call: ACP.ToolCall
        /// "4 steps before this", for a run collapsed into this one. Nil when it is the
        /// only one, which is most of them.
        var alsoRan: String?
        @State private var open = false

        private var diffs: [ACP.Diff] {
            (call.content ?? []).compactMap { if case .diff(let diff) = $0 { return diff }; return nil }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    mark
                    Text(call.heading)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color(.ink))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let alsoRan {
                        Text(alsoRan)
                            .font(.caption)
                            .foregroundStyle(Color(.quiet))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !diffs.isEmpty {
                        Button {
                            withAnimation(.snappy) { open.toggle() }
                        } label: {
                            Image(systemName: open ? "chevron.down" : "chevron.right")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ForEach(Array(diffs.enumerated()), id: \.offset) { _, diff in
                    DiffRow(diff: diff, open: open)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.block), in: .rect(cornerRadius: Style.panel))
        }

        @ViewBuilder
        private var mark: some View {
            switch call.status {
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            default:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            }
        }
    }

    private struct DiffRow: View {
        var diff: ACP.Diff
        var open: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(diff.fileName)
                        .font(.caption.monospaced())
                    Text("+\(diff.counts.added)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                    if diff.counts.removed > 0 {
                        Text("-\(diff.counts.removed)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
                if open {
                    ScrollView(.horizontal) {
                        Text(diff.newText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 220)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
                }
            }
        }
    }

    private struct Working: View {
        /// Things said to it while it was busy. Nothing is ever put to an agent mid-turn,
        /// because two of the four lose it, so they wait here and the page says so rather
        /// than leaving somebody wondering whether their nudge landed. (T373.)
        var queued: Int

        var body: some View {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working").font(.callout).foregroundStyle(.secondary)
                if queued > 0 {
                    Text(queued == 1 ? "1 waiting to be said" : "\(queued) waiting to be said")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// A button style chosen at runtime. SwiftUI's styles are each their own type, so a
/// ternary between two of them will not compile without one.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(Button($0).buttonStyle(style)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// The plan, ticking itself off. It is rewritten rather than added to, so it is a band
/// across the top rather than a row down the page: a plan that appears four times is
/// four plans.
private struct PlanBar: View {
    var entries: [ACP.PlanEntry]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(entries) { entry in
                    HStack(spacing: 5) {
                        Image(systemName: entry.isDone ? "checkmark.circle.fill"
                              : entry.isRunning ? "circle.dotted" : "circle")
                            .font(.caption)
                            .foregroundStyle(entry.isDone ? AnyShapeStyle(.green)
                                             : entry.isRunning ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(entry.title)
                            .font(.caption)
                            .strikethrough(entry.isDone, color: .secondary)
                            .foregroundStyle(entry.isDone ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quinary, in: .capsule)
                }
            }
            .padding(.horizontal, Style.cardPadding)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }
}

/// The agent has stopped and is waiting for an answer. Not a question in a list: it is
/// doing nothing until this is answered, so it sits across the top of its own page in
/// orange, and the same question is on the floor's Needs you strip and on the phone.
private struct PermissionBar: View {
    @Environment(Floor.self) private var floor
    var agent: Agent
    var waiting: AgentDaemon.Pending

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(waiting.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("It is waiting on you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ForEach(waiting.options) { option in
                let recommended = option.optionID == waiting.fallback?.optionID
                Button(option.name) {
                    Task { await floor.answer(agent.id, request: waiting.requestID, option: option.optionID) }
                }
                .buttonStyle(recommended ? AnyButtonStyle(.glassProminent) : AnyButtonStyle(.glass))
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Style.cardPadding)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }
}
