import SwiftUI
import SoftwareFactoryKit

/// What an ACP agent has done, as a page. This is what replaces the terminal, and the
/// reason for the whole rebuild: the factory is told what the agent is doing, so the page
/// can say "Editing Models.swift, 12 lines" instead of showing a picture of a CLI saying
/// so. (T373.)
///
/// It was set in a serif on a warm ground, which read as a page of a book inside an app
/// that is not one: one window, two type families, and the seam was wherever the
/// conversation started. The letters are the system's now and so is the ground, the same
/// as every other word in the app. What stays is the measure, because a line you cannot
/// find the end of is hard to read whatever it is set in. A document still opens in a
/// serif, because that is a page being read rather than a screen being used.
/// (T447, Alex, 15 Sep 2026, then Alex, 16 Sep 2026: conventional Liquid Glass.)
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
    /// Bumped when something is sent, so the page goes to the bottom at the moment you
    /// press return rather than when the answer comes back. (T483.)
    @State private var sent = 0
    /// Whether the page follows the end of the conversation. The rule is `Following` in the
    /// kit, with the trap it exists for written down beside it; this is the view's copy of
    /// the state. It starts on, because a page opens at the end.
    @State private var following = Following()
    /// How many rows the page is drawing. It starts at a page and grows as you scroll back,
    /// which is what stops `ACPTranscript.pageLength` from being a floor as well as a
    /// ceiling: folding earlier turns in would have been pointless while the page went on
    /// drawing only the last sixty. (T542.)
    @State private var rows = ACPTranscript.pageLength
    /// Which of the matching commands Tab will take. Zero, the nearest, unless the arrows
    /// have moved it. (T543.)
    @State private var completionAt = 0
    /// What has been said and has not come back off the daemon's log yet, drawn at the end
    /// of the conversation as though it had. The rule is `JustSaid` in the kit; this is the
    /// view's copy of it, and nothing here is ever written into the transcript. (T495.)
    @State private var mine = JustSaid()

    private var transcript: ACPTranscript { floor.transcript(agent.id) }
    private var running: AgentDaemon.Running? { floor.running(agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            if !transcript.plan.isEmpty {
                PlanBar(entries: transcript.plan)
                Divider()
            }
            // The input floats over the page rather than sitting under a rule at the
            // bottom of it. The conversation runs on behind it, which is what the glass
            // is for: you can see there is more page under the thing you are typing into.
            // (Alex, 16 Sep 2026.)
            page
                // Nothing floats while a question is open: the question is in the page and
                // the field is gone, because answering is the only thing to do.
                .overlay(alignment: .bottom) { if !isAsking { sayBox } }
        }
        .task(id: agent.id) {
            // Another agent's page, so anything of mine still waiting belongs to the one I
            // have just left: it is about that conversation and not this one. (T495.)
            mine = JustSaid()
            // Back to a page. Whatever was scrolled back to belongs to the agent just left.
            rows = ACPTranscript.pageLength
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
                        if let said = Self.whatCameBefore(row) {
                            Text(said)
                                .font(Style.Text.quiet)
                                .foregroundStyle(.tertiary)
                        }
                        Entry(row: row).id(row.id)
                    }
                    if running?.isPrompting == true {
                        Working(waiting: running?.waitingToSay ?? [])
                    }
                    // What you have said that has not landed yet, at the end of the chat in
                    // the order it will land, drawn the way anything you said is drawn: it
                    // is yours, it is simply still in the queue. They were a line of faint
                    // text under Working, which read as a note about the agent rather than
                    // as your own words waiting. (T484, Alex, 15 Sep 2026.)
                    ForEach(Array((running?.waitingToSay ?? []).enumerated()), id: \.offset) { _, line in
                        Queued(text: line)
                    }
                    // Two or more waiting is usually one instruction typed in pieces, and
                    // sent one at a time it becomes the agent doing the first and then being
                    // interrupted by the second, which is what the queue exists to avoid.
                    // Offered rather than done: the queue stays one at a time and this is
                    // where you say that a run of them is really one thing.
                    // (Alex, 16 Sep 2026, T541.)
                    if (running?.waitingToSay.count ?? 0) > 1 {
                        Button("Send these \(running?.waitingToSay.count ?? 0) as one",
                               systemImage: "arrow.triangle.merge") {
                            Task { if let why = await floor.merge(agent.id) { refused = why } }
                        }
                        .buttonStyle(.borderless)
                        .font(Style.Text.quiet)
                        .help("Join them into one thing to say, so the next turn has all of it")
                    }
                    // And what you have said in the last second, before the daemon's log
                    // has come back round. Drawn exactly as it will be drawn when it does,
                    // so it is one line that stays rather than a line that appears twice.
                    // (T495.)
                    ForEach(mine.waiting) { one in
                        if let why = one.failed {
                            DidNotGo(text: one.words, why: why) { takeBack(one) }
                        } else {
                            Asked(text: one.words)
                        }
                    }
                    // The question, in the conversation rather than over it.
                    //
                    // It floated at the foot on glass, where the field floats, and the
                    // field can float because it is two lines high and you can read round
                    // it. A question is half the window, so it covered the conversation
                    // that led to it, which is the part you need in order to answer.
                    // In the page it scrolls with everything else and the words above it
                    // stay readable. (Alex, 16 Sep 2026: "show in the chat. Currently it is
                    // over the chat. You cannot see the relevant chat under it.")
                    asking
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
            // A conversation grows downwards from the bottom of the window, the way every
            // chat and every terminal does. Without this a short one sits at the top with
            // the rest of the window empty beneath it, so the first few things an agent
            // says appear at the top and creep down, and "scroll to the bottom" does
            // nothing because there is nothing to scroll.
            // (Alex, 16 Sep 2026: the chat does not scroll to the bottom.)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // **But not when the content grows.** Anchoring size changes to the bottom
            // follows the end whatever the person is doing, which is the opposite of what
            // was asked: scroll up to read and the next word drags you back down, and no
            // flag of ours can stop it because SwiftUI has already moved the page. Anchored
            // to the top, growth never moves the viewport, and the following is done
            // deliberately below, only when the person is at the end.
            .defaultScrollAnchor(.top, for: .sizeChanges)
            // Whether to follow the bottom, and **it only changes when you move the page**.
            //
            // This is the whole of it, and getting it wrong is subtle. The obvious version
            // asks the geometry "is the bottom on screen?" on every change and believes the
            // answer. But content arriving is itself a geometry change: the content grows,
            // the offset does not, so the bottom is suddenly off screen and the flag goes
            // false, a hair before the code that wanted to scroll there reads it. So the
            // first thing an agent said turned following off for good, which is exactly
            // backwards: the page stopped following the moment there was something to
            // follow.
            //
            // So the flag is only touched when the content height is unchanged, which means
            // the offset moved because somebody moved it. Scroll up and it goes off; scroll
            // back down to the end and it comes on again; an agent talking never touches it.
            // Our own scrollTo lands at the bottom with the height unchanged, so it sets
            // itself back on, which is what you want after a send.
            // (Alex, 16 Sep 2026: it needs to auto-scroll new content into view unless the
            // user has scrolled up.)
            .onScrollGeometryChange(for: Following.Where.self) {
                Following.Where(offset: $0.contentOffset.y, container: $0.containerSize.height,
                                content: $0.contentSize.height)
            } action: { was, now in
                following.moved(from: was, to: now)
            }
            // Scrolling back. Reaching the top asks for the stretch before this one, and
            // that one for the one before it, until the top of the log is on the page.
            //
            // A whole window early rather than at the very top: a page that waits until you
            // hit the end stops dead while it reads, and the read is off the main actor so
            // arriving early costs nothing but arriving late is felt. `Floor.readEarlier`
            // takes one at a time per agent, so holding the scroll at the top asks once and
            // then once more each time the page grows, rather than a dozen times at once.
            // (Alex, 16 Sep 2026: for chats provide a way to infinite scroll back.)
            //
            // Only when there is something to scroll. A conversation shorter than the window
            // sits at offset zero for ever, which reads as "at the top" on every geometry
            // change there is, so this asked for more of the log over and over on the one
            // kind of page that has none.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.containerSize.height
                    && geometry.contentOffset.y < Self.nearTheTop
            } action: { was, nearTop in
                guard nearTop, !was else { return }
                showMore()
            }
            // The newest thing is what you came to read, the same as a terminal always
            // showed you the bottom.
            //
            // On the transcript's revision rather than on the last row's id, because an
            // agent mid-sentence changes neither that nor the count of rows: a message
            // chunk joins the entry before it, so a page following the bottom stopped
            // following it for the whole of a long answer and picked it up again at the
            // end. Every update moves the revision, which is what "something happened"
            // means. (Alex, 16 Sep 2026: make sure the chat transcript scrolls on new
            // message.)
            //
            // And only while the bottom is already on screen. Following it on every chunk
            // is right when you are watching the agent work and wrong the moment you scroll
            // up to read something, because the next word drags you back down. A terminal
            // has always behaved this way: it follows the tail until you look away from it,
            // and picks it up again when you come back.
            .onChange(of: transcript.revision) { _, _ in
                guard following.isOn else { return }
                withAnimation(.snappy) { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
            // A field growing from one line to four moves the page under it by three
            // lines, which is exactly the last three lines you were reading.
            .onChange(of: inputHeight) { _, _ in
                guard following.isOn else { return }
                withAnimation(.snappy) { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
            // Two moments, not one. A row arriving is the agent talking; a send is you
            // talking, and the page moved only when the round trip came back, so what you
            // had just said appeared below the fold for a second. (T483.)
            //
            // This one goes wherever you are: saying something is asking to be taken to the
            // end of the conversation, because what you said is now the end of it.
            .onChange(of: sent) { _, _ in
                following.said()
                withAnimation(.snappy) { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onAppear { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            // With no field floating there is nothing to leave room for, and the reserve is
            // whatever the field was last measured at, which would be a gap under the
            // question.
            .onChange(of: isAsking) { _, nowAsking in
                if nowAsking { inputHeight = 0 }
            }
            // The two places a send can land, and the echo goes when it reaches either.
            // (T495.)
            .onChange(of: transcript.entries.count) { _, _ in settle() }
            .onChange(of: running?.waitingToSay) { _, _ in settle() }
            // Not while it is working: the Working row in the page says that already, and
            // an empty page under a spinner is not an empty page. (T496.) Nor while it is
            // asking: the question is in the page now, so "Nothing yet. Say something to it
            // below" drew across the top of it and was wrong twice over, since there is
            // something there and there is no below to say it in. (Alex, 16 Sep 2026.)
            .overlay {
                if shown.isEmpty, mine.isEmpty, !isAsking, running?.isPrompting != true { nothingYet }
            }
        }
    }

    private static let bottom = -1

    /// How near the end counts as at it. A few points of slack, because a page that has
    /// just animated to the bottom is often a pixel short of it and would otherwise decide
    /// it had been scrolled away from.

    /// How near the top asks for the stretch before. A window early rather than at the very
    /// top, so the earlier turns are folded by the time you reach where they go.
    private static let nearTheTop = 600.0

    /// What the first row says about everything above it, or nothing when there is nothing
    /// above it. A number when the fold knows one, and the plain fact when it does not:
    /// a page opened at the end of a long log never read the rest, so it cannot count it,
    /// and a count it made up would be worse than none. (T467, then T511.)
    private static func whatCameBefore(_ row: ACPTranscript.Shown) -> String? {
        if row.earlier > 0 { return "\(row.earlier) earlier, in the log" }
        if row.more { return "Reading earlier turns" }
        return nil
    }

    /// Whether what you type will wait rather than go. Nothing is said to an agent in the
    /// middle of a turn: two of the four CLIs lose it and one throws its own work away, so
    /// the daemon queues instead. The placeholder has said so since T373; the button now
    /// says it too. (T540.)
    private var willQueue: Bool { running?.isPrompting == true }

    /// What an empty field sends. The word the placeholder shows, so what you see is what
    /// goes. (T482.)
    private static let carryOn = "continue"

    /// What the page draws. Thinking is not in it and there is no way to ask for it: an
    /// agent's thoughts are nine tenths of the words and a tenth of the interest, and a
    /// control in front of something nobody opens is still a control. The phone never drew
    /// them, so this makes the two pages the same rather than making them differ. Runs of
    /// tool calls are collapsed to their most recent by `ACPTranscript.page`.
    /// (T496, Alex, 15 Sep 2026: "remove the ability to show thinking. No one want that.")
    private var shown: [ACPTranscript.Shown] {
        transcript.page(last: rows)
    }

    /// Reaching the top asks for more of the conversation, and there are two places it can
    /// come from. Usually the fold already holds more than the page is drawing, because
    /// `pageLength` is a drawing budget rather than everything that is known, so the first
    /// answer is to draw more of what is here. When that runs out, the rest is on disk and
    /// `Floor.readEarlier` fetches the stretch before this one.
    ///
    /// Both are cheap and neither blocks: growing the budget is a redraw, and the read is
    /// off the main actor and takes one at a time per agent, so holding the scroll at the
    /// top asks once and then once more each time the page grows. (T542.)
    private func showMore() {
        let folded = transcript.page(last: 0).count
        if rows < folded {
            rows = min(folded, rows + ACPTranscript.pageLength)
            return
        }
        guard floor.hasEarlier(agent.id) else { return }
        Task {
            await floor.readEarlier(agent.id)
            rows += ACPTranscript.pageLength
        }
    }

    /// A page with no rows on it, and which of the four reasons it is empty.
    ///
    /// Thinking being one of them is what T496 turned up: an agent can spend a whole turn
    /// thinking and say nothing, and with the thoughts no longer drawn that page has
    /// nothing on it. Nothing yet would be a lie there, and Say something to it below is
    /// advice to interrupt an agent that is working. The Show thinking toggle used to cover
    /// this case by accident. (T496.)
    ///
    /// Reading is the fourth, and it is the one this page most often is. The log is read
    /// off the main actor, so for the first moment of a page there is an empty transcript
    /// that means "not read yet" rather than "nothing in it". T503 answered that by drawing
    /// nothing at all, which is honest and says nothing; a page that has been asked for and
    /// is blank should say what it is doing. (T511.)
    private var nothingYet: some View {
        VStack(spacing: 6) {
            Text(emptyPage.0)
                .font(.headline)
            if let detail = emptyPage.1 {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Style.page)
    }

    private var emptyPage: (String, String?) {
        if running?.state == .starting {
            return ("Starting", "It is handshaking with the factory.")
        }
        if !floor.hasBeenRead(agent.id) {
            return ("Reading the log", nil)
        }
        // Something in the log and nothing on the page is a turn that was all thinking.
        // Everything else an agent does is drawn.
        if !transcript.entries.isEmpty {
            return ("It has only been thinking",
                    "Nothing it has said out loud yet. What it thought is in the log.")
        }
        return ("Nothing yet", "Say something to it below.")
    }

    /// The newest question this agent has raised and nobody has answered, or nil.
    ///
    /// Newest rather than oldest for the reason T481 gives about the agent's own questions:
    /// it is the last thing that happened, the conversation above it is what led to it, and
    /// that is where the page is already scrolled to. Its own, not the floor's: another
    /// agent's question belongs on another agent's page.
    private var raised: Escalation? {
        model.snapshot.escalations
            .filter { $0.agentID == agent.id && $0.isOpen }
            .max { $0.raised < $1.raised }
    }

    /// Whether this agent is waiting on an answer from the person, whichever of the three
    /// ways it asked.
    private var isAsking: Bool {
        running?.waiting != nil || running?.asking != nil || raised != nil
    }

    /// The question the agent is waiting on, at the end of the conversation.
    ///
    /// **It is in the page, not over it** (Alex, 16 Sep 2026: "show in the chat. Currently
    /// it is over the chat. You cannot see the relevant chat under it."). The field can
    /// float because it is two lines high and you read round it. A question is half the
    /// window, and the half it covered was the conversation that led to it, which is what
    /// you need in order to answer. Here it scrolls with everything else, the words above
    /// it stay where they are, and nothing needs a material of its own.
    ///
    /// **It still replaces the field**, which is the other half of what was asked: an agent
    /// waiting on you is doing nothing else until the answer lands, so answering is the only
    /// thing to do and a field to type something else into is a second door out of a room
    /// with one. The field comes back when the agent does.
    ///
    /// **All three kinds, one rule.** An agent can ask three ways: a permission request
    /// about a tool, its own question through the protocol, and one raised through
    /// `escalation_raise`. T481 put the first two in the conversation and left the field
    /// under them, and the third was not on this page at all, so the page answered the same
    /// situation three ways depending on how the agent happened to ask. The kind of question
    /// is the agent's business; what it means for the person is the same.
    /// (T481, then T530 and Alex, 16 Sep 2026.)
    ///
    /// A permission request comes first because it is the hardest block: the turn itself is
    /// stopped mid-tool-call, rather than the agent having gone on to something else.
    @ViewBuilder
    private var asking: some View {
        if let waiting = running?.waiting {
            Asking(title: waiting.title, detail: nil,
                   options: waiting.options.map {
                       Asking.Choice(id: $0.optionID, name: $0.name,
                                     recommended: $0.optionID == waiting.fallback?.optionID)
                   }) { option in
                Task { await floor.answer(agent.id, request: waiting.requestID, option: option) }
            }
        } else if let asked = running?.asking {
            Asking(title: asked.question, detail: nil,
                   options: asked.options.map {
                       Asking.Choice(id: $0.value, name: $0.title, detail: $0.detail)
                   }) { option in
                Task { await floor.answerQuestion(agent.id, request: asked.requestID,
                                                  option: option, words: "") }
            }
        } else if let raised {
            EscalationCard(escalation: raised, place: .atTheFoot, model: model)
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
            // The commands, met where you are already typing. Only after a slash at the
            // front of the field, which is somebody asking for them. (T494.)
            if !completions.isEmpty { completing }
            field
            HStack(spacing: 8) {
                modePicker
                commandPicker
                sessionOptions
                Spacer(minLength: 8)
                Text(runningWith)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

    /// The commands that match what has been typed so far. Empty unless the field starts
    /// with a slash and the word is still being typed.
    private var completions: [ACP.Command] {
        ACP.Slash.matches(for: words.wrappedValue, in: running?.commands ?? [])
    }

    /// The commands matching what has been typed, above the field, nearest first. Picking
    /// one types it in rather than sending it, because a command usually wants something
    /// after it.
    ///
    /// **Tab and Return finish the word, and the arrows move between them** (Alex,
    /// 16 Sep 2026, twice: auto-complete rather than picking from a drop-down, then show
    /// them vertically and let the user go up and down). T494 put the commands where you
    /// are already typing and left the only way of taking one a click, which means leaving
    /// the keyboard in the middle of a sentence.
    ///
    /// A list down the page rather than a row across it. A row of capsules holds a name and
    /// nothing else, so eighty-four commands came out as eighty-four words you had to
    /// already know the meaning of; down the page each one has room for what it does and
    /// what it takes after it, which is the whole reason for looking. The one the arrows
    /// are on is marked, and it is what Tab and Return take.
    /// (Alex, 16 Sep 2026: show the hints vertically and let the user go up and down.)
    private var completing: some View {
        ScrollViewReader { rows in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(completions.enumerated()), id: \.element.id) { index, command in
                        Button { take(command) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("/\(command.name)")
                                    .font(Style.Text.row.monospaced())
                                // What it takes after it, where the agent said: /loop wants
                                // an interval and a prompt, and a name on its own does not
                                // say that. (T546.)
                                if let hint = command.hint {
                                    Text(hint)
                                        .font(Style.Text.quiet.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 8)
                                if let brief = command.brief {
                                    Text(brief)
                                        .font(Style.Text.quiet)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == completionAt ? AnyShapeStyle(.tint.opacity(0.25))
                                                              : AnyShapeStyle(.clear))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            // Five rows or so. Longer and the list is the page rather than a thing over it.
            .frame(maxHeight: 160)
            .background(.background.secondary, in: .rect(cornerRadius: Style.panel))
            .overlay {
                RoundedRectangle(cornerRadius: Style.panel).strokeBorder(.separator, lineWidth: 1)
            }
            // Arrowing past the bottom of a list that does not follow is arrowing into
            // nothing.
            .onChange(of: completionAt) { _, at in
                withAnimation(.snappy) { rows.scrollTo(at, anchor: .center) }
            }
        }
    }

    /// Types one in, and puts the marker back to the first for whatever is typed next.
    private func take(_ command: ACP.Command) {
        words.wrappedValue = ACP.Slash.picked(command, in: words.wrappedValue)
        completionAt = 0
    }

    /// The one the arrows are on, for Tab and Return.
    private func takeHighlighted() {
        let matches = completions
        guard !matches.isEmpty else { return }
        take(matches[min(completionAt, matches.count - 1)])
    }

    /// Tab, and the arrows, while a command is being typed. Answers whether the key was
    /// taken: anything not about the completions is handed back, so Tab still moves focus
    /// and the arrows still move the caret when there is nothing to complete.
    private func completionKey(_ press: KeyPress) -> KeyPress.Result {
        let matches = completions
        guard !matches.isEmpty else { return .ignored }
        switch press.key {
        case .tab:
            takeHighlighted()
            return .handled
        case .downArrow:
            completionAt = (completionAt + 1) % matches.count
            return .handled
        case .upArrow:
            completionAt = (completionAt + matches.count - 1) % matches.count
            return .handled
        case .escape:
            // Not a command after all. The row goes and what was typed stays, because
            // taking the words away too would be answering a different question.
            completionAt = 0
            return .ignored
        default:
            return .ignored
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
                .background(.quaternary, in: .capsule)
            }
            if let refused {
                Text(refused)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
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

    /// How this agent's session is set: its model, how hard it is thinking, whatever else
    /// it lists. Read, not set.
    ///
    /// The agent has been sending these at `session/new` all along and nothing read them,
    /// so effort and fast mode were reachable nowhere in the factory and a person had no
    /// way to see which model an agent was actually on without reading the command that
    /// started it. (R69, measured off 44 transcripts, which is how the note in ACP.swift
    /// saying this was "newer than what we read" turned out to be wrong.)
    ///
    /// The label is the values rather than the word Options, because the values are the
    /// answer and a menu you have to open to learn anything is a menu you will not open.
    /// Nothing is drawn for an agent that sends none, which is every CLI but Claude Code so
    /// far as we have seen: an empty menu saying Options would be the factory claiming to
    /// know something it does not. (T546.)
    @ViewBuilder
    private var sessionOptions: some View {
        if let running, !running.options.isEmpty {
            Menu {
                ForEach(running.options) { option in
                    Section(option.name) {
                        Text(option.value ?? "not said")
                        if let detail = option.detail, !detail.isEmpty { Text(detail) }
                        if option.choices.count > 1 {
                            Text("of \(option.choices.joined(separator: ", "))")
                        }
                    }
                }
            } label: {
                Text(running.options.compactMap(\.value).filter { $0 != "default" }
                        .joined(separator: " · "))
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("How \(agent.label)'s session is set up")
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
            // The placeholder is the default: send with nothing typed and that is what the
            // agent gets. "Continue" is the ordinary thing to want, and since the nudge
            // went in T470 there was no one-keystroke way to say it. (T482 and T465, Alex,
            // 15 Sep 2026.)
            //
            // It read "Queue: continue" while the agent was working, which was the field
            // explaining the queue in the one place that has to say what pressing return
            // will send. The words are the words whether they go now or in a minute, and
            // the send button grew a clock in T540 to say which, so the placeholder was the
            // second thing saying it and the only one that changed what it claimed to send.
            // (Alex, 16 Sep 2026.)
            TextField(Self.carryOn, text: words, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.body)
                // Return takes the command the arrows are on rather than sending, while the
                // list is up. Nobody types a slash and two letters meaning to send them, and
                // the list being open is the field saying it is in the middle of a word.
                // (T546.)
                .onSubmit { completions.isEmpty ? say() : takeHighlighted() }
                // Tab finishes the command being typed, and the arrows move between the
                // matches. Before this the only way to take one was to click it, which is
                // leaving the keyboard in the middle of typing a sentence. Every other key
                // is handed straight back, so Tab still moves focus and the arrows still
                // move the caret when there is nothing to complete. (T543.)
                .onKeyPress(keys: [.tab, .upArrow, .downArrow, .escape], action: completionKey)
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
            // The arrow grows a clock when the words will wait. Nothing is said to an agent
            // mid-turn, so pressing send during one queues it, and the field already says so
            // in its placeholder while the button went on promising to send. The same arrow
            // with one mark added rather than a different symbol: it is the same control
            // doing the same thing a moment later, and a control that changes shape reads as
            // a different control. (Alex, 16 Sep 2026.)
            Button(willQueue ? "Queue" : "Send",
                   systemImage: willQueue ? "arrow.up.circle.badge.clock" : "arrow.up.circle.fill",
                   action: say)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                // Never disabled: an empty field means the default, which is the one thing
                // you most often want to say. (T482.)
                .help(willQueue
                      ? "It is mid-turn, so this waits until the turn ends. An empty field says \(Self.carryOn)."
                      : "Send it. An empty field says \(Self.carryOn).")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        // The same measure as the page, so the field lines up with what it is answering
        // rather than running the width of the window.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Style.card))
    }

    private func say() {
        // Nothing typed is not nothing meant: it is the placeholder, which is the default.
        let typed = words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = typed.isEmpty ? Self.carryOn : typed
        let files = attached
        Drafts.shared.clear(Drafts.agent(agent.id))
        attached = []
        refused = nil
        // Sent, so the microphone stops: it was listening for this and there is nothing
        // left for the next words to land in. (T445.)
        if model.dictation.isListening { Task { _ = await model.dictation.stop() } }
        sent += 1
        // On the page at once, before anything has been asked of the daemon. The words
        // reach the page off the log, which is up to a refresh away, and in between they
        // were gone from the field and nowhere else, which reads as a send that did not
        // happen. Refreshing the moment the daemon answers was the smaller fix and it is
        // not the right one: folding a busy agent's log costs about half a second and it
        // happens on the main actor, so the page would hitch exactly when you pressed
        // Send. This costs nothing and shows the words sooner. (T495.)
        let echo = mine.add(said, alreadySaid: JustSaid.timesSaid(
            said, in: transcript.entries, queued: running?.waitingToSay ?? []))
        // Straight to the agent, not through the mailbox. This is a person typing on the
        // agent's own page, which is what the terminal was, and the terminal never
        // queued: the mailbox and its cap of three are for messages from other agents.
        // The daemon writes it into the transcript, so it appears here either way.
        Task {
            if let why = await floor.say(said, to: agent.id, files: files) {
                mine.failed(echo, why: why)
            }
        }
    }

    /// The echoes the real record has caught up with, dropped. Run whenever the
    /// conversation or the queue changes, which is the only way either of them can.
    private func settle() {
        guard !mine.isEmpty else { return }
        let entries = transcript.entries
        let queued = running?.waitingToSay ?? []
        mine.settle { JustSaid.timesSaid($0, in: entries, queued: queued) }
    }

    /// Words back into the field, for one that did not go. Added rather than written over:
    /// whatever is in the field now was typed after, and losing that to get the other back
    /// is the same bug in the other direction.
    private func takeBack(_ one: JustSaid.Words) {
        let now = words.wrappedValue
        words.wrappedValue = now.isEmpty ? one.words : now + "\n" + one.words
        mine.drop(one.id)
    }

    // MARK: The pieces

    private struct Entry: View {
        var row: ACPTranscript.Shown

        var body: some View {
            switch row.entry.kind {
            case .asked(let text): Asked(text: text)
            case .said(let text): Said(text: text)
            // Thinking is not drawn anywhere: `ACPTranscript.page` never hands one over.
            // It is still folded and still in the log. (T496.)
            case .thought: EmptyView()
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
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                // Set into the page rather than sitting on it: no shadow, no gloss.
                .background(.quaternary, in: .rect(cornerRadius: Style.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: Style.panel)
                        .strokeBorder(.quaternary, lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Something you said that has not landed yet. The same bubble as anything else you
    /// said, because it is the same thing, with a mark saying it is still waiting: nothing
    /// is put to an agent mid-turn, so it goes when this turn ends. (T484.)
    private struct Queued: View {
        var text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                // One word. "Waiting for this turn to end" explains the mechanism, which is
                // ours rather than yours, and it was the longest thing on a row whose point
                // is the words above it. Queued says the state and nothing else.
                // (Alex, 16 Sep 2026.)
                Label("Queued", systemImage: "clock")
                    .font(Style.Text.quiet)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: Style.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Style.panel)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Words that did not go. The same bubble as anything else you said, so it is plainly
    /// yours, with the daemon's own reason under it and the words offered back: an agent
    /// that has stopped has nobody to say anything to, and the one thing that must not
    /// happen is the sentence disappearing as though it had been taken. (T495.)
    private struct DidNotGo: View {
        var text: String
        var why: String
        var takeBack: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                HStack(spacing: 8) {
                    Label(why, systemImage: "exclamationmark.triangle")
                        .font(Style.Text.quiet)
                        .foregroundStyle(Color.orange)
                    Button("Put it back in the field", action: takeBack)
                        .buttonStyle(.borderless)
                        .font(Style.Text.quiet)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.quaternary, in: .rect(cornerRadius: Style.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Style.panel)
                    .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
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
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
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

        /// How tall an opened output gets before it scrolls inside itself. Tall enough to
        /// read a screenful, short enough that one long command does not become the page.
        static let outputHeight = 220.0

        private var diffs: [ACP.Diff] {
            (call.content ?? []).compactMap { if case .diff(let diff) = $0 { return diff }; return nil }
        }

        /// What the tool said, where it says anything. A call that reports its output as
        /// text drew a heading and nothing at all, which is the one case a person would
        /// actually notice: the row said a command ran and not what it printed. Folded
        /// behind the same chevron as a diff, because output is long and the row is not.
        /// (T493, off A82's audit.)
        private var said: [String] {
            (call.content ?? []).compactMap { if case .text(let text) = $0 { return text }; return nil }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        /// A terminal this client cannot show. We declare no terminal capability, so an
        /// agent handing one over is handing over an id we can do nothing with; saying so
        /// is better than the row looking empty.
        private var terminals: Int {
            (call.content ?? []).filter { if case .terminal = $0 { return true }; return false }.count
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
                        .foregroundStyle(call.kind == .execute ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(call.kind == .execute ? .middle : .tail)
                    if let alsoRan {
                        Text(alsoRan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !diffs.isEmpty || !said.isEmpty {
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
                if open {
                    ForEach(Array(said.enumerated()), id: \.offset) { _, text in
                        // Both ways. It scrolled sideways only, inside a box capped at 220
                        // points, so everything a command printed past about a dozen lines
                        // was clipped with no way to reach it: the row said it had output,
                        // opened to show you the first dozen lines of it, and hid the rest
                        // with no indication there was a rest. A long output is the case you
                        // open one of these for.
                        // (Alex, 16 Sep 2026: make sure chats scroll out output too.)
                        ScrollView([.vertical, .horizontal]) {
                            Text(text)
                                .font(Style.Text.machine)
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: Self.outputHeight)
                        .background(.quaternary, in: .rect(cornerRadius: 8))
                    }
                }
                if terminals > 0 {
                    Text(terminals == 1 ? "It opened a terminal, which this app cannot show"
                                        : "It opened \(terminals) terminals, which this app cannot show")
                        .font(Style.Text.quiet)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary, in: .rect(cornerRadius: Style.panel))
        }

        /// How it went. A call that worked is the ordinary case and gets the quiet ink:
        /// a green tick is a small celebration, and there are dozens of these in a turn.
        /// Red stays, because a call that failed is the one you want to find.
        /// (Alex, 16 Sep 2026.)
        @ViewBuilder
        private var mark: some View {
            switch call.status {
            case .completed: Image(systemName: "checkmark").foregroundStyle(.secondary)
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
                    // Both ways, the same as a tool's output: a file is longer than a dozen
                    // lines more often than it is wider than the window.
                    ScrollView([.vertical, .horizontal]) {
                        Text(diff.newText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: ToolRow.outputHeight)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
                }
            }
        }
    }

    private struct Working: View {
        /// Things said to it while it was busy, in the order they will be said. Nothing is
        /// ever put to an agent mid-turn, because two of the four lose it, so they wait
        /// here and the page says so rather than leaving somebody wondering whether what
        /// they said landed. (T373.) How many; the words themselves are rows at the end of
        /// the chat, because they are things you said and not a note about the agent.
        /// (T465, then T484.)
        var waiting: [String]

        var body: some View {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working").font(Style.Text.row).foregroundStyle(.secondary)
                // The same word the rows below use. This said "5 waiting to be said" six
                // inches above five rows each marked Queued, which is one fact in two
                // vocabularies on one screen. (Alex, 16 Sep 2026.)
                if !waiting.isEmpty {
                    Text("\(waiting.count) queued")
                        .font(Style.Text.quiet)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
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

/// A question the agent is blocked on, in the conversation where it asked it.
///
/// Both kinds: a permission request about a tool, where the factory marks the agent's own
/// fallback, and the agent's own question, which carries no recommendation because nothing
/// on the wire does. It is not a question in a list, which is an agent carrying on with
/// something else; this one is an agent doing nothing at all until it is answered, and the
/// same question is on the Needs you strip, on the phone and on the Lock Screen.
/// (T373, moved into the page in T481.)
private struct Asking: View {
    struct Choice: Identifiable {
        var id: String
        var name: String
        var detail: String = ""
        var recommended = false
    }

    var title: String
    var detail: String?
    var options: [Choice]
    var answer: (String) -> Void

    /// The same shape a raised question takes at the end of a conversation: the line saying
    /// who it is waiting on, the question, and the choices as one ruled list. It was a
    /// tinted card with a sheet of glass under each option, which is what the raised
    /// question's card was before it was cut back, and having two of the three kinds look
    /// one way and the third another is the drift that putting them all in one place exists
    /// to stop. (Alex, 16 Sep 2026.)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.orange)
                Text("It is waiting on you.")
                    .font(Style.Text.quiet)
                    .foregroundStyle(Color.orange)
            }
            Text(title)
                .font(Style.Text.rowName)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Style.Text.row)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Button { answer(option.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // Numbered, like a raised question's answers, and for the same reason:
                    // these are buttons that answer, not a choice you tick and confirm.
                    Text("\(index + 1)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(option.name).font(Style.Text.row.weight(.medium))
                            if option.recommended {
                                Text("Recommended")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tint.opacity(0.18), in: .capsule)
                            }
                        }
                        if !option.detail.isEmpty {
                            Text(option.detail)
                                .font(Style.Text.quiet)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                    .buttonStyle(.plain)
                    if option.id != options.last?.id { Divider() }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Style.panel).strokeBorder(.separator, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
