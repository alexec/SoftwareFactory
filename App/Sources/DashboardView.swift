import AppKit
import SwiftUI
import SoftwareFactoryKit

/// The dashboard: the numbers, then what needs you. The agents have a page
/// of its own.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    /// The way to the status board. It came off the sidebar in T360 and had no other way
    /// in, so it was a page nobody could reach; the number of agents is the number it
    /// explains, so that tile is its door. (T392.)
    var openStatusReports: () -> Void = {}
    /// How much room the Needs you strip has, so a question can take it. (T263.)
    @State private var stripWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            // Needs you first. The page you land on is the page that answers what needs
            // you, and it had four tiles above that in a bigger typeface, three of them
            // reading zero the day anybody looked. The most important object on a page is
            // the largest thing on it. (T409, off the hierarchy rules in the brief.)
            VStack(alignment: .leading, spacing: 28) {
                needsYou
                summary
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Summary

    /// Agents that have not said anything within the hour. `StatusReportBoard` decides
    /// what quiet means; nothing here does.
    private var quiet: Int {
        StatusReportBoard.quiet(in: model.snapshot, now: .now)
    }

    private var summary: some View {
        let d = model.dashboard
        // Tiles wrap onto a second row in a narrow window rather than squeezing their words.
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
            StatTile(value: d.inProgress, label: d.inProgress == 1 ? "task in progress" : "tasks in progress", symbol: "hammer")
            // There is no tile counting the questions any more. The questions
            // themselves are the section above this one, so a number saying how many
            // of them there are, six inches under them, is the same fact at a second
            // altitude. The sidebar's Dashboard row keeps its badge, which is a
            // different job: that one is a door, and says come here. (T409.)
            // The one tile that goes somewhere. How many agents there are is a number
            // you read once; how many of them have said nothing for an hour is the
            // one worth acting on, and the page that lists them is behind it.
            StatTile(value: d.agents.count,
                     label: d.agents.count == 1 ? "agent registered" : "agents registered",
                     symbol: "person.2",
                     tint: quiet > 0 ? Color.orange : nil,
                     note: quiet > 0 ? (quiet == 1 ? "1 has gone quiet" : "\(quiet) have gone quiet") : nil,
                     open: openStatusReports)
            StatTile(value: d.heldCount, label: d.heldCount == 1 ? "resource held" : "resources held", symbol: "lock.rectangle.stack")
        }
        .frame(maxWidth: 900)
    }

    // MARK: Needs you

    @ViewBuilder
    private var needsYou: some View {
        let open = model.dashboard.openEscalations
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Needs you")
                    .font(.title2.weight(.semibold))
                if !open.isEmpty {
                    Text("Click an option and the agent is told.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if model.notifier.standing == .notAsked {
                NotificationPrimer()
            }
            if open.isEmpty {
                EmptyLine(text: "Nothing needs you.", symbol: "checkmark.circle")
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(open) { escalation in
                            EscalationCard(escalation: escalation, showsProject: true, model: model)
                                .frame(width: cardWidth(for: open.count))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
            }
        }
    }

    /// How wide one question gets. A question is words with options under them, and at
    /// 380 points they were a column of two-word lines with the wrapping doing the
    /// reading for you. The cards take the window instead: one question has the whole
    /// strip, and several share it, down to a width worth reading at and never wider
    /// than a paragraph should be. (T263.)
    private func cardWidth(for count: Int) -> CGFloat {
        guard stripWidth > 0 else { return Self.narrowestCard }
        let fits = max(1, Int(stripWidth / Self.narrowestCard))
        let columns = CGFloat(max(1, min(count, fits)))
        let gaps = 14 * (columns - 1)
        let each = (stripWidth - gaps) / columns
        return min(max(each, Self.narrowestCard), Self.widestCard)
    }

    /// Narrower than this and the options wrap into a stack of fragments; wider and a
    /// line of the question is too long to take in at a glance.
    private static let narrowestCard: CGFloat = 420
    private static let widestCard: CGFloat = 760

}

struct StatTile: View {
    var value: Int
    var label: String
    var symbol: String
    var tint: Color?
    /// A second line under the label, for the thing the number does not say: how many of
    /// those agents have gone quiet. It carries the tile's colour, so an orange tile is
    /// orange because of the words on it.
    var note: String?
    /// Where the number is explained at length, if there is such a page. A tile with one
    /// is the whole surface you click, which is what `.plain` means here.
    var open: (() -> Void)?

    var body: some View {
        if let open {
            Button(action: open) { tile }
                .buttonStyle(.plain)
        } else {
            tile
        }
    }

    private var tile: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                // Under the heading of the section above it, not over it. At largeTitle
                // these numbers were the biggest type in the app, which said that the
                // count of held resources mattered more than the question an agent is
                // stuck on. (T409.)
                Text(value, format: .number)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(tint ?? Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardSurface(tint: tint)
        .animation(.snappy, value: value)
    }
}

struct EmptyLine: View {
    var text: String
    var symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

/// One agent: who it is, what it is on, and when it last said anything.
/// The whole card opens the agent.
struct AgentCard: View {
    /// Every card on the grid is this tall, whatever it has to say: the middle two lines
    /// are given the room and the text truncates into it, so a long description cannot
    /// push one card past its neighbours. (Alex, 13 Sep 2026.)
    static let height: CGFloat = 132
    /// What it says it is, and what it is on: two lines, always.
    static let middle: CGFloat = 40

    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    @Environment(Floor.self) private var floor
    @Environment(AgentShells.self) private var shells
    var status: Dashboard.AgentStatus
    var select: (UUID) -> Void

    /// Whether there is a terminal to look at right now. Every agent is one the factory
    /// started, so this is no longer a question about where the agent came from: it is
    /// only whether the window is still here to watch. (T-session, 13 Sep 2026.)
    private var hasTerminal: Bool {
        terminals.session(for: status.agent) != nil
            || terminals.isHeld(status.agent.id.uuidString)
    }

    /// Its process has gone. Worth saying out loud: the terminal outlives the agent by
    /// design, so a window that is still there proves nothing, and until now a stopped
    /// agent looked exactly like a quiet one for the hour it takes the factory to give
    /// up on it. An agent that never reported a pid says nothing either way rather than
    /// being called dead. (Alex, 13 Sep 2026.)
    private var hasStopped: Bool { status.activity == .stopped }

    var body: some View {
        Button {
            model.clearBell(status.agent)
            select(status.agent.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AgentActivityDot(activity: status.activity)
                    Text(status.agent.label)
                        .font(.headline)
                    if hasStopped { StoppedMark() }
                    AgentBellMark(ringing: status.agent.bel)
                    Spacer(minLength: 0)
                }
                Text(status.project?.name ?? "No project")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    // The same test the sidebar uses: a tmux title is the last command the
                    // pane ran, and a command is the machine talking rather than news.
                    // (T407.)
                    if AgentLine.worthSaying(status.agent.title) {
                        Text(status.agent.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(status.agent.title)
                    }
                    if let task = status.task {
                        Text(task.title)
                            .font(.callout)
                            .lineLimit(1)
                            .help(task.title)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: Self.middle, alignment: .topLeading)
                HStack(spacing: 6) {
                    // Where it runs, so you know before you click whether there is a
                    // terminal on its page or only what it has told the factory. The
                    // symbol says it and the tooltip spells it out: the words sat on
                    // every card saying the same thing, and the time needs the room.
                    // (Alex, 13 Sep 2026.)
                    Image(systemName: hasTerminal ? "macwindow" : "arrow.up.forward.app")
                        .help(hasTerminal
                              ? "Its terminal is here: its page shows it working, and you can type to it"
                              : "Its terminal has gone: its page shows what it has told the factory, and nothing to type into")
                    // The cards go down to 190 points wide, so on the narrowest one the
                    // time drops its prefix rather than losing its last characters;
                    // "2 minutes ago" reads as a last seen on its own.
                    // (A9, 13 Sep 2026: T157.)
                    let lastSeen = status.agent.lastSeen.formatted(.relative(presentation: .named))
                    ViewThatFits(in: .horizontal) {
                        Text("Last seen \(lastSeen)")
                        Text(lastSeen)
                    }
                    .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(height: Self.height, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cardSurface()
        .overlay(alignment: .topTrailing) {
            // Start, and nothing for an agent that is running. Nudge was here, and a card
            // is not the place to talk to an agent: its page is, where you can see what it
            // is doing and say something that is not one canned line. (T412, Alex,
            // 15 Sep 2026.)
            if status.canResume {
                Button("Start") {
                    Task { _ = await StartAgent.resume(agent: status.agent, model: model, terminals: terminals, floor: floor) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Start it back up in the conversation it was having")
                .padding(10)
            }
        }
        .help("Show \(status.agent.label)")
        .contextMenu {
            if status.canResume {
                Button("Start \(status.agent.label)") {
                    Task { _ = await StartAgent.resume(agent: status.agent, model: model, terminals: terminals, floor: floor) }
                }
            }
            if status.canStop {
                Button("Stop \(status.agent.label)", role: .destructive) {
                    stopAgent(status.agent, model: model, floor: floor)
                }
            }
            if Agents.mayArchive(status.agent) {
                Button("Archive \(status.agent.label)") {
                    stopAgent(status.agent, model: model, floor: floor)
                    model.archive(status.agent)
                }
            }
            Button("Delete \(status.agent.label)", role: .destructive) {
                stopAgent(status.agent, model: model, floor: floor)
                floor.forget(status.agent.id)
                shells.closeAll(for: status.agent.id, terminals: terminals)
                model.delete(status.agent)
            }
        }
    }
}

struct AgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalSessions.self) private var terminals
    @Environment(Floor.self) private var floor
    @Environment(AgentShells.self) private var shells
    var status: Dashboard.AgentStatus
    /// Back to the page this was opened from. Nil when there is nowhere to go.
    var back: (() -> Void)?
    /// The documents column. On by default: what the agent has written down is the thing
    /// you most want beside the terminal, and the column is not drawn at all when it has
    /// written nothing. (T311.)
    @State private var chosenSide: Side? = .documents
    @State private var resumeError: String?
    /// How wide the documents are, remembered across launches and across agents: it is
    /// how you like to read, not a property of one agent. (T329.)
    @AppStorage("agentDocumentsWidth") private var documentsWidth = 420.0



    private struct ResourceLease: Identifiable {
        var resource: Resource
        var lease: Lease

        var id: UUID { lease.id }
    }

    private var agent: Agent { status.agent }
    private var leases: [ResourceLease] {
        model.snapshot.resources.flatMap { resource in
            model.snapshot.leases
                .filter { $0.resourceID == resource.id && $0.agentID == agent.id && $0.isActive(now: .now) }
                .map { ResourceLease(resource: resource, lease: $0) }
        }
    }

    /// Two columns on this page, three in the window with the sidebar counted: the
    /// terminal, and what the agent has written. It is what you came to watch and what
    /// it has to say, and nothing between them.
    ///
    /// What the agent is on, holding and running used to be a column of its own, which
    /// made four. It is a band on two lines now, always there, costing a little height
    /// rather than a quarter of the width. (T314.) It sits under the name and runs the
    /// whole way across, because it is about the agent and not about the terminal: under
    /// the terminal it read as that pane's footer, and it went on describing the agent
    /// while the documents beside it were something else entirely.
    /// (T332, Alex, 15 Sep 2026.)
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The band is only the leases now, and only when it holds any. What it used to
            // lead with was the tasks in the agent's name, which the sidebar already lists
            // under that agent, numbered and blocked-first. (T463.)
            if !leases.isEmpty {
                strip
                Divider()
            }
            sideIcons
            Divider()
            GeometryReader { page in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        // An ACP agent has no terminal and does not need one: the page is
                        // its transcript, which says what it is doing rather than showing
                        // a picture of it saying so. (T373.)
                        if agent.speaksACP {
                            AgentTranscriptView(agent: agent)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let session = terminals.session(for: agent) {
                            // The pane is the terminal it was made with: a representable
                            // hands its view over once and SwiftUI keeps it. Going from
                            // one agent to the next in the sidebar reuses this position,
                            // so without an identity of its own the pane went on showing
                            // the agent you came from. (Alex, 14 Sep 2026.) The identity
                            // is the run rather than the session, because starting a
                            // stopped agent back up makes a new terminal under the same
                            // session id and the page has to follow it.
                            TerminalPanel(terminal: session.terminal)
                                .id(session.run)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            noTerminal
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let side {
                        ColumnGrip(width: $documentsWidth, beside: page.size.width)
                        Group {
                            switch side {
                            case .documents: documents
                            case .shells: AgentShellsPane(agent: agent, folder: status.project?.path)
                            case .files:
                                if let url = OpenFolder.url(for: status.project) {
                                    FileBrowser(root: url)
                                }
                            }
                        }
                        .frame(width: ColumnGrip.width(documentsWidth, beside: page.size.width))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: agent.id) { await reattach() }
        // Opening the page is the look it rang for, however you got here: from its card,
        // or from its row in the sidebar. (T225.)
        .onAppear { model.clearBell(agent) }
        .alert("It did not start", isPresented: Binding(get: { resumeError != nil }, set: { if !$0 { resumeError = nil } })) {
            Button("OK") { resumeError = nil }
        } message: {
            Text(resumeError ?? "")
        }
        .toolbar {
            if let back {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: back)
                        .help("Back to where you came from")
                }
            }
        }
    }

    /// What can sit beside the agent: what it has written, and shells you have opened in
    /// its folder.
    ///
    /// The shells are the part that used to be a kind of agent, which it never was. What
    /// a person wants is to run something by hand where the agent is working and watch
    /// both, so a terminal is opened beside one now rather than being launched instead of
    /// one. (Alex, 16 Sep 2026.)
    ///
    /// The files are the third, and the folder icon used to leave the app for the Finder to
    /// show them. Three ways into the same folder, and now all three of them open beside the
    /// agent rather than two of them doing that and one sending you somewhere else.
    /// (Alex, 16 Sep 2026.)
    private enum Side: String, Hashable {
        case documents, shells, files
    }

    /// Which pane is showing, or none. Small icons rather than toggles, because only one of
    /// them can be showing and a row of toggles says otherwise.
    private var side: Side? {
        guard let chosen = chosenSide else { return nil }
        if chosen == .documents, !hasDocuments { return nil }
        if chosen == .files, OpenFolder.url(for: status.project) == nil { return nil }
        return chosen
    }

    private var sideIcons: some View {
        HStack(spacing: 4) {
            // The mode moved down to sit under the field it affects. (T431.)
            Spacer(minLength: 0)
            // Nothing written, no icon. It was drawn and disabled, which the plain button
            // style and the explicit foregroundStyle below it rendered identically to a
            // live one: an icon that looks like every other icon and does nothing when
            // you click it. The column it opens is already not drawn for an agent that
            // has written nothing, and this is the same rule one step earlier.
            // (Alex, 16 Sep 2026.)
            if hasDocuments {
                icon(.documents, "doc.richtext", on: "What it has written")
            }
            icon(.shells, shells.has(agent.id) ? "apple.terminal.fill" : "apple.terminal",
                 on: "A shell in this agent's folder, beside it")
            // The folder itself, beside the shell: both are the agent's folder, opened two
            // ways. It was up in the header next to the project's name (Alex, 15 Sep 2026),
            // and it opened the Finder until it was asked to open here instead. The Finder
            // is a button inside the browser now, for the things only it can do.
            if OpenFolder.url(for: status.project) != nil {
                icon(.files, "folder", on: "What is in this agent's folder")
            }
        }
        .padding(.horizontal, Style.cardPadding)
        .padding(.vertical, 5)
    }

    private func icon(_ which: Side, _ symbol: String, on help: String) -> some View {
        Button {
            withAnimation(.snappy) { chosenSide = chosenSide == which ? nil : which }

        } label: {
            Image(systemName: symbol)
                .font(.callout)
                .frame(width: 26, height: 22)
                .background(chosenSide == which ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(chosenSide == which ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(help)
    }

    /// Opening the page is the whole instruction. If this app has lost the terminal but
    /// tmux still holds it, take it back up now rather than asking with a button: you
    /// came here to watch the agent work, and an empty page with something to click
    /// first is a page that has not done its job.
    ///
    /// Finding out whether tmux still has it means running tmux, which waits, so that
    /// part happens off the main thread and the page stays live while it does. Nothing
    /// here ever blocks the window. (Alex, 13 Sep 2026: not at the price of a beachball.)
    private func reattach() async {
        // Nothing to attach to: the daemon has been holding the conversation all along
        // and the transcript is on disk.
        guard !agent.speaksACP else { return }
        guard terminals.session(for: agent) == nil else { return }
        let id = agent.id.uuidString
        await terminals.lookForHeldSessions()
        guard terminals.session(for: agent) == nil, terminals.isHeld(id) else { return }
        terminals.attach(id)
    }

    /// One line across the top: who it is, where, what it says it is doing, and when it
    /// last said anything. The
    /// dot says how it is doing, and says it in a word if you hold the pointer over it.
    /// (Alex, 13 Sep 2026: the word beside the dot said it twice.)
    private var header: some View {
        HStack(spacing: 10) {
            AgentActivityDot(activity: status.activity)
            Text(agent.label)
                .font(.title3.weight(.semibold))
            if status.activity == .stopped { StoppedMark() }
            AgentBellMark(ringing: agent.bel)
            if let project = status.project {
                Text(project.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // The line the agent set with its terminal title is what it is doing right
            // now, so it belongs on the top row beside the project rather than at the
            // top of a column you can put away. (Alex, 15 Sep 2026.)
            if !agent.title.isEmpty {
                Text(agent.title)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(agent.title)
            }
            Spacer(minLength: 12)
            // No Stop and no Archive here. Both end an agent, both are one click, and both
            // sat on the page you go to in order to watch one work and talk to it. They
            // are on the right-click of its row in the sidebar and of its card, which is
            // where ending a thing belongs: you go looking for it. Start stays, because it
            // is the one that begins something rather than ending it, and because a
            // stopped agent's page is exactly where you notice it has stopped. (T460,
            // Alex, 15 Sep 2026; Nudge went the same way in T412.)
            //
            // A stopped agent is picked back up where it left off, in the same session,
            // so it comes back knowing who it is and what it was doing. (T262.)
            if status.canResume {
                Button("Start") {
                    Task { resumeError = await StartAgent.resume(agent: agent, model: model, terminals: terminals, floor: floor) }
                }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .help("Start it back up in the conversation it was having")
            } else if let why = status.whyNoResume {
                // Not a disabled button. A control that can never work on this agent is
                // worse than no control: it says come back later, and later never comes.
                // (T373.)
                Text("Cannot be started back up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(why)
            }
            Text(agent.lastSeen, format: .relative(presentation: .named))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// What it is holding, under its name.
    ///
    /// This was a column of labelled rows, which is a lot of window for a few short facts,
    /// and then a band of two lines (T314, T332). The first line was the tasks in the
    /// agent's name, and the sidebar lists those under the agent already, numbered and
    /// blocked first, so the page was repeating the thing you clicked through from. What
    /// is left is the leases, which are nowhere else. (T463, Alex, 15 Sep 2026.)
    private var strip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                holding
                Spacer(minLength: 8)
            }
        }
        .font(Style.Text.row)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// The resources it has leased. Nothing is drawn when it holds none, which is what
    /// this comment has always said and what the code did not do: it wrote "Holding
    /// nothing" two lines under a chip saying which task the agent is holding, so the
    /// band used the word for a lease on one line and for a task on the other and
    /// contradicted itself for anybody reading the words rather than the layout. Holding
    /// no lease is the ordinary case, and the ordinary case is not news. (T418, off T395.)
    @ViewBuilder
    private var holding: some View {
        if !leases.isEmpty {
            ForEach(leases) { held in
                StripChip(
                    text: held.resource.name,
                    detail: "until \(held.lease.until.formatted(date: .omitted, time: .shortened))",
                    help: held.lease.why.isEmpty
                        ? "Held until \(held.lease.until.formatted(date: .omitted, time: .shortened))"
                        : "\(held.lease.why) · until \(held.lease.until.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    /// The other half of the page when there is no terminal to show. An external agent
    /// never had one here; an embedded one whose terminal has gone is being looked for
    /// as this draws. Either way the page says which rather than showing a blank.
    private var noTerminal: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            EmptyLine(
                // Whether the factory started this one is what it was launched with.
                // There is no separate embedded flag any more: the session is the id.
                text: agent.launchedWith == nil
                    ? "It registered from somewhere else, so there is no terminal here to watch."
                    : "Its terminal is not on this Mac any more. What it has written is beside this.",
                symbol: "macwindow.badge.plus")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    /// What this agent has written: its status report first, then its documents. They
    /// were rows in the column beside the terminal, each behind a triangle, which is a
    /// fine way to list documents and no way to read one. A document is reading matter,
    /// so it gets a column of its own and a page to sit on. (T311.)
    private var mine: [Artifact] { Artifacts.produced(by: agent.id, in: model.snapshot.artifacts) }
    private var hasDocuments: Bool { !mine.isEmpty }

    private var documents: some View {
        // Delete is here now. It was left off on the argument that a document belongs to
        // the project rather than to the agent that wrote it (T266), which is true of
        // where it lives and beside the point when you are looking at one: this is the
        // page where you read an agent's status report and its notes, so it is where you
        // notice one that should not be there, and the project page was the only place
        // that could take it off. (T414, Alex, 15 Sep 2026.)
        ArtifactBrowser(documents: mine) { model.delete($0) }
            .id(agent.id)
    }

}

/// One fact in the band under the terminal: a name, and a quieter word after it. The
/// shape a task, a lease and anything else the strip has to say all take, so the line
/// reads as a row of the same thing rather than a sentence that keeps changing font.
private struct StripChip: View {
    var text: String
    var detail: String
    var help: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.4), in: .capsule)
        .help(help)
    }
}


/// Stops an agent, whoever is holding it. The daemon holds an ACP one and the kernel
/// holds the rest, and `AppModel.stop` knows only about the second. One call at every
/// Stop, so a new way of running an agent is one edit here rather than five. (T373.)
@MainActor
func stopAgent(_ agent: Agent, model: AppModel, floor: Floor) {
    if agent.speaksACP {
        _Concurrency.Task { await floor.stop(agent.id) }
        return
    }
    model.stop(agent)
}

/// Every message nobody has delivered yet, given to its agent: nudges the person sent,
/// nudges `agent_nudge` asked for, messages from other agents, and the factory's own
/// hourly ask for a status report. One path, because they are the same thing.
///
/// Two ways of arriving now, and the agent's runtime picks. One in a terminal is typed
/// to, exactly as a person at the keyboard would; one the daemon holds is told with
/// `session/prompt`, which is the better of the two and the same idea. A message is only
/// marked delivered when something took it, so one sent to an agent with nowhere to put
/// it waits rather than vanishing. (T195; T373.)
@MainActor
func deliverPendingMessages(model: AppModel, terminals: TerminalSessions, floor: Floor) async {
    for agent in model.snapshot.agents {
        let waiting = model.undelivered(for: agent.id)
        guard !waiting.isEmpty else { continue }
        if agent.speaksACP {
            // Nothing to attach to and nothing to wake: the daemon has been holding the
            // conversation all along, whether or not this app has been looking at it.
            guard floor.running(agent.id)?.state == .running else { continue }
            for message in waiting {
                // A message left undelivered is one still in the mailbox, which is where it
                // belongs until something takes it.
                guard await floor.say(message.promptLine, to: agent.id) == nil else { break }
                model.delete(message)
            }
            continue
        }
        // Pick the session back up if this app has restarted since the agent was launched.
        // A terminal is only attached when somebody opens that agent's page, and a message
        // is meant to arrive while the agent is working, not whenever its page is next
        // looked at. tmux has been holding the session all along. (Alex, 14 Sep 2026.)
        terminals.attach(agent.id.uuidString)
        for message in waiting {
            guard terminals.sendLine(message.promptLine, to: agent.id.uuidString) else { break }
            // Delivered is arrived, and an arrived message is not an inbox item any more.
            // (Alex, 14 Sep 2026: once it is sent, take it out of their inbox.)
            model.delete(message)
        }
    }
}

/// An agent, small: its dot and its name, in a capsule that opens the agent. Used
/// wherever a row has to say who is on something.
struct AgentChip: View {
    var status: Dashboard.AgentStatus
    /// A task in an agent's name that nobody has started reads as waiting, not working.
    var waiting = false
    var select: (UUID) -> Void

    var body: some View {
        Button { select(status.agent.id) } label: {
            HStack(spacing: 4) {
                if waiting {
                    Image(systemName: "person")
                } else {
                    AgentActivityDot(activity: status.activity)
                }
                Text(status.agent.label)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(waiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(waiting ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.quaternary), in: .capsule)
        }
        .buttonStyle(.plain)
        .help(waiting ? "Waiting for \(status.agent.label): task_next hands it to them and nobody else"
                      : "\(status.agent.label) is on it")
    }
}

/// An agent whose process has gone, on a card or a page header. One symbol, and the
/// tooltip says what it means and what is still true: the terminal is there, the last
/// words are readable, the agent is not running. (Alex, 13 Sep 2026.)
struct StoppedMark: View {
    var body: some View {
        Image(systemName: "stop.circle")
            .foregroundStyle(.secondary)
            .help("Stopped: its terminal is still here and you can read what it said, but the agent is not running in it any more")
            .accessibilityLabel("Stopped")
    }
}

/// BEL from the agent's terminal: it wants a look. The bell is always there, quiet and
/// grey, so you know where to look for it; when the agent rings it fills in, turns orange
/// and wiggles until the page is opened. A mark that only exists while something is wrong
/// is a mark nobody learns to read. (Alex, 14 Sep 2026.)
struct AgentBellMark: View {
    var ringing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Nothing at all until it rings. It used to be drawn on every agent, grey and quiet,
    /// on the argument that a mark which only exists while something is wrong is one
    /// nobody learns to read. With eight agents on the floor that is eight grey bells
    /// saying nothing, and the one orange bell among them is harder to find, not easier:
    /// the quiet ones are what it has to be picked out from. A bell that is only ever
    /// there when it means something needs no learning. (T289, Alex, 15 Sep 2026.)
    @ViewBuilder var body: some View {
        if ringing {
            Image(systemName: "bell.fill")
                .foregroundStyle(Color.orange)
                .symbolEffect(.wiggle, options: .repeating, isActive: !reduceMotion)
                .help("It rang for your attention")
                .accessibilityLabel("Wants a look")
                .transition(.opacity)
        }
    }
}


struct NotificationPrimer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Taktu: Software Factory can tell you when a question arrives, even with this window hidden. The banner carries the options, so you answer from it. Nothing leaves this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Continue") { model.askForNotifications() }
                .buttonStyle(.glassProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
