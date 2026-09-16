import SwiftUI
import SoftwareFactoryKit

/// What an ACP agent has done, as a page. This is what replaces the terminal, and the
/// reason for the whole rebuild: the factory is told what the agent is doing, so the page
/// can say "Editing Models.swift, 12 lines" instead of showing a picture of a CLI saying
/// so. (T373.)
///
/// It was set in a serif, which read as a page of a book inside an app that is not one:
/// one window, two type families, and the seam was wherever the conversation started.
/// The paper, the measure and the warmth stay, because those are the theme; the letters
/// are the system's, the same as every other word in the app. A document still opens in a
/// serif, because that is a page being read rather than a screen being used.
/// (T447, Alex, 15 Sep 2026.)
struct AgentTranscriptView: View {
    @Environment(Floor.self) private var floor
    @Environment(AppModel.self) private var model
    var agent: Agent
    /// What has been typed and not sent. Through Drafts so it is still here when you come
    /// back from looking something up, which is what view state never was. (T429.)
    private var words: Binding<String> {
        Binding(get: { Drafts.shared.text(for: Drafts.agent(agent.id)) },
                set: { Drafts.shared.keep($0, for: Drafts.agent(agent.id)) })
    }
    @State private var showsThinking = false
    /// How tall the floating input actually is, measured rather than guessed. It grows to
    /// four lines as you type, and the page kept a fixed 78 points for it, so a long thing
    /// to say sat on top of the last thing the agent said. (T387.)
    @State private var inputHeight = 0.0
    /// Files dropped on the field, waiting to go with the next thing said. Paths rather
    /// than bytes: the daemon reads them, because it is the side that knows what this
    /// agent takes. (T427.)
    @State private var attached: [String] = []
    /// Why something dropped here will not be sent, until the next thing is dropped or
    /// said. An agent that cannot see an image has to say so when you drop it, not after.
    @State private var refused: String?

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
            // The input floats over the page rather than sitting under a rule at the
            // bottom of it. The conversation runs on behind it, which is what the glass
            // is for: you can see there is more page under the thing you are typing into.
            // (Alex, 16 Sep 2026.)
            page
                .overlay(alignment: .bottom) { sayBox }
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
                        // The page says what it is not showing rather than beginning
                        // mid-conversation with no explanation. The whole of it is in the
                        // log, which is the record. (T467.)
                        if row.earlier > 0 {
                            Text("\(row.earlier) earlier, in the log")
                                .font(Style.Text.quiet)
                                .foregroundStyle(Color(.faint))
                        }
                        Entry(row: row).id(row.id)
                    }
                    if running?.isPrompting == true {
                        Working(waiting: running?.waitingToSay ?? [])
                    }
                    // The room the input needs, as the last thing on the page rather than
                    // as padding around it. Scrolling to the bottom puts the bottom of
                    // this against the bottom of the window, so what the agent said lands
                    // above the input instead of behind it. As padding it was outside the
                    // marker being scrolled to, and every scroll parked the last line
                    // under the glass. (T387.)
                    Color.clear.frame(height: inputHeight).id(Self.bottom)
                }
                .padding(.horizontal, Style.page)
                .padding(.top, Style.page)
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
            // A field growing from one line to four moves the page under it by three
            // lines, which is exactly the last three lines you were reading.
            .onChange(of: inputHeight) { _, _ in
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
                .foregroundStyle(Color(.quiet))
        }
    }

    /// The field that used to be a terminal you typed into. It is `session/prompt` now,
    /// which is better, but it is the same thing: words to the agent.
    /// The field, with whatever has been dropped on it above the words, and what this
    /// agent is underneath: how much it may do on the left, what it is running on the
    /// right. They were up in the band at the top of the page, two inches from anything
    /// they affect; here they are attached to the thing you type into, which is the thing
    /// they are about. (T431, Alex, 15 Sep 2026.)
    private var sayBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attached.isEmpty || refused != nil { dropped }
            field
            HStack(spacing: 8) {
                modePicker
                commandPicker
                thinkingToggle
                Spacer(minLength: 8)
                Text(runningWith)
                    .font(.caption)
                    .foregroundStyle(Color(.faint))
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: Paper.measure)
        .padding(.horizontal, Style.page)
        .padding(.bottom, 12)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { inputHeight = $0 }
        // A screenshot is the ordinary way to say what is wrong with a screen, so it is
        // dropped on the agent rather than described to it. What the agent will take is
        // its own answer, off its handshake, and an agent that cannot see one says so
        // here rather than swallowing it. (T427.)
        .dropDestination(for: URL.self) { urls, _ in
            take(urls)
            return true
        }
    }

    /// What is waiting to go with the next thing said, and what will not go at all.
    private var dropped: some View {
        HStack(spacing: 8) {
            ForEach(attached, id: \.self) { path in
                Button {
                    attached.removeAll { $0 == path }
                } label: {
                    Label((path as NSString).lastPathComponent, systemImage: "paperclip")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Take it off again")
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.block), in: .capsule)
            }
            if let refused {
                Text(refused)
                    .font(.caption)
                    .foregroundStyle(Color(.alarm))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// What this agent will take, as it said at its handshake. Nothing known means nothing
    /// but words, which is the honest default for an agent the daemon is not holding.
    private var takes: ACP.Attachments { running?.takes ?? ACP.Attachments() }

    private func take(_ urls: [URL]) {
        refused = nil
        for url in urls where url.isFileURL {
            guard let attachment = AgentFloor.attachment(at: url.path) else {
                refused = "\(url.lastPathComponent) is not something an agent can read."
                continue
            }
            let (block, why) = ACP.block(for: attachment, takes: takes)
            if block == nil { refused = why }
            else { attached.append(url.path) }
        }
    }

    /// What this agent may do without asking, in its own words. The menu lists exactly
    /// what this agent offers, because the four disagree about what the choices even are,
    /// and nothing is drawn for one that offers none, which is Grok. (Alex, 16 Sep 2026.)
    @ViewBuilder
    private var modePicker: some View {
        if let running, !running.modes.isEmpty {
            Menu {
                ForEach(running.modes) { mode in
                    Button {
                        Task { await floor.setMode(agent.id, to: mode.id) }
                    } label: {
                        if mode.id == running.mode {
                            Label(mode.name, systemImage: "checkmark")
                        } else {
                            Text(mode.name)
                        }
                    }
                    .help(mode.detail ?? "")
                }
            } label: {
                Text(running.modes.first { $0.id == running.mode }?.name ?? "Mode")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("What \(agent.label) may do without asking")
        }
    }

    /// Thinking, folded away or not. It sat to the left of the field, in front of the
    /// words, which is a control about the page standing in the way of the thing you type
    /// into. It belongs with the other two things that are about this agent rather than
    /// about what you are saying. (T479, Alex, 15 Sep 2026.)
    @ViewBuilder
    private var thinkingToggle: some View {
        if transcript.entries.contains(where: { if case .thought = $0.kind { return true }; return false }) {
            Button {
                withAnimation(.snappy) { showsThinking.toggle() }
            } label: {
                Label(showsThinking ? "Hide thinking" : "Show thinking",
                      systemImage: showsThinking ? "brain.filled.head.profile" : "brain.head.profile")
                    .font(Style.Text.quiet)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help(showsThinking ? "Hide what it is thinking" : "Show what it is thinking")
        }
    }

    /// What this agent can be asked to do, in its own words: its commands, as it listed
    /// them. Picking one types it into the field rather than sending it, because a command
    /// usually wants something after it. Nothing is drawn for an agent that lists none.
    /// (T436.)
    @ViewBuilder
    private var commandPicker: some View {
        if let running, !running.commands.isEmpty {
            Menu {
                ForEach(running.commands) { command in
                    Button {
                        words.wrappedValue = command.typed + words.wrappedValue
                    } label: {
                        Text("/\(command.name)")
                    }
                    .help(command.brief ?? "")
                }
            } label: {
                Text("Commands").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("What \(agent.label) can be asked to do")
        }
    }

    /// Which CLI is behind this conversation.
    private var runningWith: String {
        agent.launchedWith.flatMap(LaunchAgent.init(rawValue:))?.title ?? "Registered from elsewhere"
    }

    private var field: some View {
        HStack(spacing: 8) {
            // What the button will do, said where you are typing: sending while it works
            // queues rather than interrupts, because nothing is ever put to an agent
            // mid-turn. (T465.)
            TextField(running?.isPrompting == true
                      ? "Queue something for \(agent.label)"
                      : "Say something to \(agent.label)", text: words, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit(say)
            // Say it rather than type it. The words land in the field as they settle, so
            // what comes out is something you can correct before it goes. (T445.)
            DictateIntoField(words: words,
                             about: "Software Factory listens on this Mac and turns what you say into the words you are about to send \(agent.label). Nothing is recorded and nothing leaves the Mac.")
            if running?.isPrompting == true {
                // An icon, like Send beside it: two buttons an inch apart, one of them
                // spelling itself out, read as two different kinds of control. (T475.)
                Button("Stop", systemImage: "stop.fill") {
                    Task { await floor.cancel(agent.id) }
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Stop what it is doing, without stopping the agent")
            }
            Button("Send", systemImage: "arrow.up.circle.fill", action: say)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .disabled(words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attached.isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        // The same measure as the page, so the field lines up with what it is answering
        // rather than running the width of the window.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Style.card))
    }

    private func say() {
        let said = words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty || !attached.isEmpty else { return }
        let files = attached
        Drafts.shared.clear(Drafts.agent(agent.id))
        attached = []
        refused = nil
        // Sent, so the microphone stops: it was listening for this and there is nothing
        // left for the next words to land in. (T445.)
        if model.dictation.isListening { Task { _ = await model.dictation.stop() } }
        // Straight to the agent, not through the mailbox. This is a person typing on the
        // agent's own page, which is what the terminal was, and the terminal never
        // queued: the mailbox and its cap of three are for messages from other agents.
        // The daemon writes it into the transcript, so it appears here either way.
        Task { await floor.say(said, to: agent.id, files: files) }
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
                // What you said, at the size you read it back at. (T432, Alex, 15 Sep
                // 2026: make the text larger.)
                .font(.body)
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
                // The agent's own prose is the thing this page is for, so it is the
                // largest type on it. (T432.)
                .font(.title3)
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
                .font(.body.italic())
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
                    // A command is set as a command. What the agent ran is the machine
                    // talking, and drawn in the same medium ink as a sentence it read as a
                    // heading: nine tenths of a row of somebody's shell. The house rule is
                    // that a path, a pid or a command is monospaced and quiet. (T407.)
                    Text(call.heading)
                        .font(call.kind == .execute ? .caption.monospaced() : .callout.weight(.medium))
                        .foregroundStyle(call.kind == .execute ? Color(.quiet) : Color(.ink))
                        .lineLimit(1)
                        .truncationMode(call.kind == .execute ? .middle : .tail)
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

        /// How it went. A call that worked is the ordinary case and gets the quiet ink:
        /// a green tick is a small celebration, and there are dozens of these in a turn.
        /// Red stays, because a call that failed is the one you want to find.
        /// (Alex, 16 Sep 2026.)
        @ViewBuilder
        private var mark: some View {
            switch call.status {
            case .completed: Image(systemName: "checkmark").foregroundStyle(Color(.quiet))
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
                        .foregroundStyle(Color(.quiet))
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
        /// Things said to it while it was busy, in the order they will be said. Nothing is
        /// ever put to an agent mid-turn, because two of the four lose it, so they wait
        /// here and the page says so rather than leaving somebody wondering whether their
        /// nudge landed. (T373.) It said how many and not what, which is the one thing you
        /// want to know before adding a third. (T465.)
        var waiting: [String]

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working").font(Style.Text.row).foregroundStyle(Color(.quiet))
                if !waiting.isEmpty {
                    Text(waiting.count == 1 ? "1 waiting to be said" : "\(waiting.count) waiting to be said")
                        .font(Style.Text.quiet)
                        .foregroundStyle(Color(.faint))
                }
            }
            // The words themselves, in the order they will be said, set the way anything
            // you said is set. They go when the turn ends and they are said for real.
            ForEach(Array(waiting.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Style.Text.quiet)
                    .foregroundStyle(Color(.faint))
                    .lineLimit(2)
                    .padding(.leading, 24)
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
                .foregroundStyle(Color(.alarm))
            VStack(alignment: .leading, spacing: 1) {
                Text(waiting.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("It is waiting on you.")
                    .font(.caption)
                    .foregroundStyle(Color(.quiet))
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
        .background(Color(.alarm).opacity(0.14))
    }
}
