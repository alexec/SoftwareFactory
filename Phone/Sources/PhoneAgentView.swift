import SwiftUI
import SoftwareFactoryKit

/// One agent's conversation, on the phone: what it has been doing, and a field to say
/// something to it.
///
/// The same page as the Mac's, drawn the same way and folded by the same
/// `ACPTranscript`, because it is the same conversation. It is the network half only: a
/// transcript is a file on the Mac and there is no copy in iCloud, so away from home this
/// says so rather than showing an empty page and letting you type into nothing.
/// (Alex, 16 Sep 2026.)
struct PhoneAgentView: View {
    @Environment(PhoneModel.self) private var model
    /// The agent's id rather than its status: the status is a snapshot of a moment and
    /// this page follows the agent as it works.
    var agent: UUID

    @State private var transcript = ACPTranscript()
    /// How far into the log this page has read, in bytes. Lines as well, for a Mac running
    /// a build from before it was asked for by the byte. (T506.)
    @State private var have = 0
    @State private var haveLines = 0
    /// Kept rather than held in the view, so leaving the page and coming back does not
    /// lose what you were halfway through saying. The same holder the Mac uses. (T429.)
    private var words: Binding<String> {
        Binding(get: { Drafts.shared.text(for: Drafts.agent(agent)) },
                set: { Drafts.shared.keep($0, for: Drafts.agent(agent)) })
    }
    @State private var reached = true
    /// How tall the floating input actually is. The same measurement the Mac's page takes,
    /// for the same reason: it grows to four lines and a fixed reserve does not. (T387.)
    @State private var inputHeight = 0.0
    /// Bumped when something is sent, so the page goes to the bottom as you press send
    /// rather than when the answer comes back. (T483.)
    @State private var sent = 0
    /// Whether the page follows the end. The rule is `Following` in the kit, with the trap
    /// it exists for written down beside it, and the phone uses the same one as the Mac
    /// because the two pages behaving differently is the drift `Shared` exists to stop.
    @State private var following = Following()


    private var status: Dashboard.AgentStatus? {
        model.dashboard.agents.first { $0.agent.id == agent }
    }

    private var label: String { status?.agent.label ?? "Agent" }

    /// Whether what you type will wait rather than go. Nothing is said to an agent in the
    /// middle of a turn, so the daemon queues it. (T540.)
    private var willQueue: Bool { status?.agent.isPrompting == true }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(transcript.page()) { row in
                        Row(row: row).id(row.id)
                    }
                    // The question, in the conversation rather than over it: it is half the
                    // screen, and the half it covered was the conversation that led to it,
                    // which is what you need in order to answer. The same as the Mac's.
                    // (Alex, 16 Sep 2026: "show in the chat. Currently it is over the chat.
                    // You cannot see the relevant chat under it.")
                    if let raised {
                        EscalationCard(escalation: raised, place: .atTheFoot, model: model)
                    }
                    // The room the input needs, on the page rather than around it, so
                    // scrolling to the bottom lands the last thing said above the glass
                    // and not behind it. (T387.)
                    Color.clear.frame(height: inputHeight).id(Self.bottom)
                }
                .padding(.horizontal, Style.cardPadding)
                .padding(.top, Style.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Grows downwards from the bottom, the way every chat does. A short one sat at
            // the top with the rest of the screen empty under it. The same as the Mac's.
            // (Alex, 16 Sep 2026: the chat does not scroll to the bottom.)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // Not on size changes: anchoring those to the end follows it whatever the person
            // is doing, so the next word drags you back down and no flag of ours can stop it.
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .overlay(alignment: .bottom) { foot }
            // Whether the end is on screen, which is what decides whether the page follows
            // it. The same rule and the same slack as the Mac's.
            .onScrollGeometryChange(for: Following.Where.self) {
                Following.Where(offset: $0.contentOffset.y, container: $0.containerSize.height,
                                content: $0.contentSize.height)
            } action: { was, now in
                following.moved(from: was, to: now)
            }
            // On the revision, not the count of rows: a message chunk joins the entry
            // before it, so neither the count nor the last row's id moves while an agent is
            // mid-sentence, and the page stopped following the bottom for the whole of a
            // long answer. And only while the bottom is on screen, or the next word drags
            // you back down out of whatever you had scrolled up to read. The same fix as
            // the Mac's. (Alex, 16 Sep 2026: make sure the chat transcript scrolls on new
            // message.)
            .onChange(of: transcript.revision) { _, _ in
                guard following.isOn else { return }
                withAnimation(.snappy) { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: inputHeight) { _, _ in
                guard following.isOn else { return }
                withAnimation(.snappy) { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
            // Saying something is asking to be taken to the end, because what you said is
            // now the end.
            .onChange(of: sent) { _, _ in
                following.said()
                withAnimation(.snappy) { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
            // No field floating means nothing to leave room for, and the reserve is
            // whatever the field was last measured at.
            .onChange(of: raised == nil) { _, noQuestion in
                if !noQuestion { inputHeight = 0 }
            }
            // Not while it is asking: the question is in the page, so an empty-page notice
            // would draw across the top of it. The same as the Mac's.
            .overlay { if transcript.entries.isEmpty, raised == nil { nothing } }
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: agent) { await keepUp() }
    }

    private static let bottom = -1

    /// The newest question this agent has raised and nobody has answered, or nil.
    private var raised: Escalation? {
        model.snapshot.escalations
            .filter { $0.agentID == agent && $0.isOpen }
            .max { $0.raised < $1.raised }
    }

    /// The field, or the question the agent is waiting on. The same rule as the Mac's: an
    /// agent that has raised one is blocked on the decision until it lands, so the question
    /// takes the field's place rather than sitting above it. The phone is the Mac seen from
    /// somewhere else, and a question that replaced the field on one and not the other would
    /// be the same agent behaving two ways. (T530, Alex, 16 Sep 2026.)
    /// Nothing floats while a question is open: the question is in the page and the field
    /// is gone, because answering is the only thing to do.
    @ViewBuilder
    private var foot: some View {
        if raised == nil { sayBox }
    }

    /// The transcript, and then whatever is added to it. Only the new lines each time:
    /// a conversation of a thousand lines does not want fetching whole every few seconds.
    private func keepUp() async {
        transcript = ACPTranscript()
        have = 0
        haveLines = 0
        while !Task.isCancelled {
            if let more = await model.conversation(with: agent, from: have, after: haveLines) {
                reached = true
                // The log is shorter than where this page had got to, so it is not the
                // conversation that was being read: the agent was started again. What has
                // been folded is the last one's, and folding onto it would show this agent
                // answering the last one's questions. (T506.)
                if more.startedAgain { transcript = ACPTranscript() }
                if !more.lines.isEmpty {
                    transcript = transcript.folding(more: more.lines)
                }
                // Whichever the Mac answered with is the one that moves.
                have = more.next ?? have
                haveLines = more.total ?? (haveLines + more.lines.count)
            } else {
                reached = false
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private var nothing: some View {
        VStack(spacing: 8) {
            Text(reached ? "Nothing yet" : "Out of reach")
                .font(.headline)
                .foregroundStyle(Color.primary)
            Text(reached
                 ? "Say something to \(label) below."
                 : "An agent's conversation lives on the Mac, so this page needs to be on the same network as it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Style.page)
        }
    }

    private var sayBox: some View {
        HStack(spacing: 8) {
            // The placeholder is the default here too, and the Mac's word for it. (T482.)
            TextField("continue", text: words, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.callout)
                .submitLabel(.send)
                .onSubmit(say)
            // The same arrow with a clock on it when the words will wait, as on the Mac.
            // The phone reads `isPrompting` off the agent's record, which is the daemon's
            // own answer written down for exactly this kind of question. (T540.)
            Button(willQueue ? "Queue" : "Send",
                   systemImage: willQueue ? "arrow.up.circle.badge.clock" : "arrow.up.circle.fill",
                   action: say)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .disabled(!model.canTalkToAgents)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Style.card))
        .padding(.horizontal, Style.cardPadding)
        .padding(.bottom, 10)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { inputHeight = $0 }
    }

    private func say() {
        let typed = words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = typed.isEmpty ? "continue" : typed
        Drafts.shared.clear(Drafts.agent(agent))
        sent += 1
        Task { await model.say(said, to: agent) }
    }

    /// One row, drawn the way the Mac draws it: prose as prose, a tool call as a block
    /// set into it.
    private struct Row: View {
        var row: ACPTranscript.Shown

        var body: some View {
            switch row.entry.kind {
            case .asked(let text):
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.quaternary, in: .rect(cornerRadius: Style.panel))
                    .overlay(RoundedRectangle(cornerRadius: Style.panel)
                        .strokeBorder(.quaternary, lineWidth: 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .said(let text):
                MarkdownText(text: text)
                    .font(.title3)
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .thought:
                // Not on a phone. Thinking is nine tenths of the words and a tenth of the
                // interest, and there is no room to fold it away behind a control here.
                EmptyView()
            case .tool(let call):
                HStack(spacing: 8) {
                    mark(call)
                    Text(call.heading)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let alsoRan = row.alsoRan {
                        Text(alsoRan).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary, in: .rect(cornerRadius: Style.panel))
            }
        }

        @ViewBuilder
        private func mark(_ call: ACP.ToolCall) -> some View {
            switch call.status {
            case .completed: Image(systemName: "checkmark").foregroundStyle(.secondary)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            default: ProgressView().controlSize(.small)
            }
        }
    }
}
