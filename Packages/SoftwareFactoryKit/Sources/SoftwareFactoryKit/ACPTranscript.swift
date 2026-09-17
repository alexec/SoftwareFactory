import Foundation

/// What an agent has done, folded out of the updates it sent. This is what the agent's
/// page draws, and it is the thing that replaces scrollback: under ACP the factory is
/// told what is happening instead of reading it off a screen, so the page can say
/// "editing Models.swift, 12 lines" where before it showed a picture of a CLI saying so.
///
/// A fold rather than a stream, so it is a pure function of the log. The daemon writes
/// every line to a file and anything that wants the transcript builds it again from
/// there, which is why an agent's page has something to show after the app restarts.
///
/// The chunks are the reason this exists. An agent says one sentence as thirty
/// `agent_message_chunk` updates, a word at a time. Thirty rows in a list is not a
/// sentence. (T373.)
public struct ACPTranscript: Sendable, Equatable {
    public private(set) var entries: [Entry] = []
    /// The plan, as the agent last set it out. Not an entry, because it is rewritten
    /// rather than added to: a plan that appears four times down the page is four plans.
    public private(set) var plan: [ACP.PlanEntry] = []
    /// Context used, of what it has.
    public private(set) var used: Int?
    public private(set) var size: Int?
    /// This page was folded from partway down the log rather than from the top, so what is
    /// above the first row is not nothing. The page says so; it cannot say how much,
    /// because the point of opening at the end is not to have read the rest. (T511.)
    public var openedMidLog = false
    /// How many updates have been folded in. A number for a view to watch, because the
    /// things it was watching do not change when an agent is mid-sentence: a message chunk
    /// joins the entry before it, so the last row's id is the same and so is the count of
    /// them, and a page following the bottom stopped following it for the whole of a long
    /// answer. This changes on every update, which is what "something happened" means.
    /// (Alex, 16 Sep 2026: make sure the chat transcript scrolls on new message.)
    public private(set) var revision = 0
    /// Every tool call by id, so a later update finds the one it is about however far up
    /// the page it has scrolled.
    private var toolIndex: [String: Int] = [:]
    private var nextID = 0

    public init() {}

    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: Int
        public var kind: Kind

        public enum Kind: Sendable, Equatable {
            /// The agent talking.
            case said(String)
            /// The agent thinking. Drawn folded: it is worth having and not worth
            /// reading most of the time.
            case thought(String)
            /// What the factory or the person said to it. Echoed back by `session/load`,
            /// and written down when we prompt, so the page reads as a conversation
            /// rather than as one side of one.
            case asked(String)
            case tool(ACP.ToolCall)
        }

        public var text: String? {
            switch kind {
            case .said(let t), .thought(let t), .asked(let t): t
            case .tool: nil
            }
        }

        public var tool: ACP.ToolCall? {
            if case .tool(let call) = kind { return call }
            return nil
        }
    }

    // MARK: Folding

    /// One update in. Chunks of the same kind, arriving one after another, join the entry
    /// they belong to instead of starting a new one.
    public mutating func apply(_ update: ACP.Update) {
        revision += 1
        switch update {
        case .message(let block): append(block.text) { .said($0) }
        case .thought(let block): append(block.text) { .thought($0) }
        case .userMessage(let block): append(block.text) { .asked($0) }
        case .tool(let call):
            if let at = toolIndex[call.toolCallID], case .tool(let have) = entries[at].kind {
                entries[at].kind = .tool(have.merged(with: call))
            } else {
                toolIndex[call.toolCallID] = entries.count
                entries.append(Entry(id: take(), kind: .tool(call)))
            }
        case .plan(let entries): plan = entries
        case .usage(let used, let size):
            self.used = used
            self.size = size
        // Neither is anything a page of the conversation draws. The mode is state
        // rather than something said, and it lands on the agent's own record.
        case .mode, .commands, .other: break
        }
    }

    /// One raw line in, for replaying a log. Anything that is not an update for this
    /// session is skipped rather than refused: the log holds both directions.
    public mutating func apply(line: String) {
        if case .update(_, let update) = ACP.read(line: line) { apply(update) }
    }

    /// The whole log at once, which is what attaching to a running agent does.
    public static func folding(_ lines: [String]) -> ACPTranscript {
        var transcript = ACPTranscript()
        for line in lines { transcript.apply(line: line) }
        return transcript
    }

    /// The page an agent opens on, folded from the end of its log rather than the start.
    ///
    /// **A short page is the price, and it is worth paying.** Measured on the five biggest
    /// logs on this Mac, folding from the start against a one megabyte window:
    ///
    ///     38.6 MB  654 ms, 60 rows   →   66 ms, 11 rows
    ///     31.5 MB  526 ms, 60 rows   →  137 ms, 47 rows
    ///     20.6 MB  347 ms, 60 rows   →   18 ms, 21 rows
    ///     21.7 MB  310 ms, 31 rows   →  153 ms, 20 rows
    ///     10.9 MB  185 ms, 60 rows   →   26 ms, 60 rows
    ///
    /// The first plan was to widen until the page was full, and the measurements refused
    /// it: rows are not lines. A busy agent writes 2.6 KB a line, most of it tool call
    /// bodies that `page` collapses away, so filling sixty rows means reading most of the
    /// log, and doing it by doubling windows read the log several times over. That came out
    /// at 1.1 seconds against 310 ms, which is the fix being slower than the thing it fixed.
    ///
    /// So one window, one read, and a page that starts partway through the conversation and
    /// says so (`openedMidLog`). It fills out as the agent works, because everything after
    /// this is appended. (T511.)
    public static func opening(for agent: UUID, in store: FileStore,
                               want: Int = FileStore.transcriptOpeningBytes)
    -> (page: ACPTranscript, read: Int, from: Int) {
        let tail = store.transcriptOpening(for: agent, want: want)
        var page = ACPTranscript().folding(more: tail.lines)
        page.openedMidLog = tail.from > 0
        return (page, tail.next, tail.from)
    }

    /// The stretch before what is already folded, folded on its own and ready to go in
    /// front of it with `following`. This is one step of scrolling back.
    ///
    /// `from` is where this stretch starts, which is what to pass as `before` next time.
    /// Zero means the top of the log is on the page and there is nothing more to ask for,
    /// which is also what `openedMidLog` says once the two are joined. (T542.)
    public static func earlier(for agent: UUID, in store: FileStore, before: Int,
                               want: Int = FileStore.transcriptOpeningBytes)
    -> (page: ACPTranscript, from: Int) {
        let stretch = store.transcriptBefore(for: agent, before: before, want: want)
        var page = ACPTranscript.folding(stretch.lines)
        page.openedMidLog = stretch.from > 0
        return (page, stretch.from)
    }

    /// The lines that have arrived since, folded onto what is already folded. The same
    /// answer as folding the whole log again, because the fold carries all the state it
    /// needs: the tool calls by id, the id it is up to, and the last entry a chunk joins.
    ///
    /// That equivalence is the whole of T503. A log only ever has lines appended, and
    /// reading a day's worth of one to find the sentence that arrived a second ago was
    /// costing about half a second every two seconds. Split a log anywhere but inside a
    /// line and the two folds are equal, which is what `FileStore.transcriptTail` promises
    /// and what `theSameFoldWhetherItIsReadAllAtOnceOrABitAtATime` holds it to.
    public func folding(more lines: [String]) -> ACPTranscript {
        var transcript = self
        for line in lines { transcript.apply(line: line) }
        return transcript
    }

    /// An earlier stretch of the same log, put in front of this one. Scrolling back.
    ///
    /// **This is only safe at a turn boundary**, and that is the whole argument. Folding is
    /// append-only everywhere else, because a tool call's opening line names it and every
    /// update merges forwards into it, so two folds joined in the middle of a turn would
    /// have a call in one half and its name in the other. `FileStore.transcriptBefore` cuts
    /// where `ACP.endsATurn` says the agent had nothing open, which is the same cut
    /// `transcriptOpening` makes, so the two halves meet where nothing is unfinished:
    /// no call is open, no message is mid-sentence, nothing merges across the join.
    ///
    /// What comes from which half: the entries in order, earlier first. Everything else is
    /// this half's, because this half is the newer one. `used`, `size` and `plan` are state
    /// rather than history, and the earlier stretch's are what they were hours ago.
    /// `openedMidLog` comes from the earlier half, because it now speaks for the front of
    /// the page: false means the top of the log is on it and there is nothing more to ask
    /// for. (T542.)
    public func following(_ earlier: ACPTranscript) -> ACPTranscript {
        guard !earlier.entries.isEmpty else {
            var alone = self
            alone.openedMidLog = earlier.openedMidLog
            return alone
        }
        var joined = self
        joined.entries = earlier.entries + entries
        // Ids are a page's identity for SwiftUI and both halves counted from zero, so they
        // are handed out again over the whole thing rather than left to collide.
        for index in joined.entries.indices { joined.entries[index].id = index }
        // The index has to point at where the calls are now, or an update arriving next
        // second opens a second row for a call already on the page.
        joined.toolIndex = [:]
        for (index, entry) in joined.entries.enumerated() {
            if case .tool(let call) = entry.kind { joined.toolIndex[call.toolCallID] = index }
        }
        joined.nextID = joined.entries.count
        joined.openedMidLog = earlier.openedMidLog
        joined.revision += 1
        return joined
    }

    /// What the factory said to the agent, written down as we say it. The agent does not
    /// echo our prompts back except on a replay, so without this a page shows an agent
    /// answering questions nobody asked.
    public mutating func weSaid(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        revision += 1
        entries.append(Entry(id: take(), kind: .asked(words)))
    }

    private mutating func append(_ text: String, _ make: (String) -> Entry.Kind) {
        guard !text.isEmpty else { return }
        if let last = entries.indices.last, sameKind(entries[last].kind, make("")) {
            switch entries[last].kind {
            case .said(let have): entries[last].kind = .said(have + text)
            case .thought(let have): entries[last].kind = .thought(have + text)
            case .asked(let have): entries[last].kind = .asked(have + text)
            case .tool: break
            }
            return
        }
        entries.append(Entry(id: take(), kind: make(text)))
    }

    private func sameKind(_ a: Entry.Kind, _ b: Entry.Kind) -> Bool {
        switch (a, b) {
        case (.said, .said), (.thought, .thought), (.asked, .asked): true
        default: false
        }
    }

    private mutating func take() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// The page, with runs of tool calls collapsed to the last one.
    ///
    /// An agent reads four files, searches twice and then writes one, and every one of
    /// those is a row. What the person came for is what the agent said and what it is
    /// doing now, and a column of a dozen finished tool calls buries both. So a run of
    /// them shows its most recent, which is the one still running when there is one, and
    /// says how many went before it rather than pretending they did not happen.
    ///
    /// **Thinking is never a row.** It used to be one the page could ask for, folded away
    /// behind a Show thinking button; an agent's thoughts are nine tenths of the words and
    /// a tenth of the interest, and a control in front of something nobody opens is still a
    /// control on the page. The phone never drew them at all, so dropping the choice makes
    /// the two pages the same rather than making them differ. The thoughts are still folded
    /// and still in the log, which is the record. (T496, Alex, 15 Sep 2026: "remove the
    /// ability to show thinking. No one want that.")
    ///
    /// They are dropped before the grouping rather than after, or a thought between two
    /// tool calls would split one run into two. (Alex, 16 Sep 2026.)
    ///
    /// How much of a conversation is a page. A day's work is thousands of rows, and a view
    /// that draws all of them redraws all of them every time a word arrives; what anybody
    /// reads is the end of it. Older rows are still in the log, which is the record.
    /// (T467, Alex, 15 Sep 2026.)
    public static let pageLength = 60

    public func page(last: Int = ACPTranscript.pageLength) -> [Shown] {
        let kept = entries.filter {
            if case .thought = $0.kind { return false }
            return true
        }
        var out: [Shown] = []
        var run = 0
        for entry in kept {
            if entry.tool != nil {
                run += 1
                // Replace the one before it: only the latest of a run is drawn.
                if run > 1 { out.removeLast() }
                out.append(Shown(entry: entry, before: run - 1))
            } else {
                run = 0
                out.append(Shown(entry: entry, before: 0))
            }
        }
        // The end of it, and how much was left behind, so the page says there is more
        // rather than quietly beginning mid-conversation. A page opened at the end of a long
        // log says the same thing without a number, because it has not read the rest and a
        // count it made up would be worse than none. (T511.)
        guard last > 0, out.count > last else {
            if openedMidLog, !out.isEmpty { out[0].more = true }
            return out
        }
        var shown = Array(out.suffix(last))
        shown[0].earlier = out.count - last
        shown[0].more = openedMidLog
        return shown
    }

    /// One row of the page: the entry, and how many tool calls ran before it in the same
    /// run and are not drawn.
    public struct Shown: Identifiable, Sendable, Equatable {
        public var entry: Entry
        public var before: Int
        /// Rows before this one that the page is not drawing, on the first row only.
        public var earlier = 0
        /// There is more above this row that was never folded, because the page opened at
        /// the end of a long log. On the first row only, and without a number: it is not
        /// known, and guessing is worse than saying so. (T511.)
        public var more = false
        public var id: Int { entry.id }

        public init(entry: Entry, before: Int) {
            self.entry = entry
            self.before = before
        }

        /// What to say about the ones not drawn, or nil when this is the only one.
        public var alsoRan: String? {
            switch before {
            case 0: nil
            case 1: "1 step before this"
            default: "\(before) steps before this"
            }
        }
    }

    // MARK: What the rest of the floor asks it

    /// The line under the agent's name on its card and in the sidebar. This is what the
    /// OSC title used to be, and it is better because it is the truth rather than
    /// whatever the CLI decided to put in its window title: the tool it is running now,
    /// else the last thing it said.
    public var line: String? {
        for entry in entries.reversed() {
            if let call = entry.tool, !call.isFinished { return call.heading }
            if case .said(let text) = entry.kind { return Self.firstLine(text) }
        }
        for entry in entries.reversed() {
            if let call = entry.tool { return call.heading }
        }
        return nil
    }

    /// Whether it is doing something right now, which is a tool call still open. Silence
    /// with nothing open is an agent waiting for a person.
    public var isBusy: Bool {
        entries.contains { ($0.tool.map { !$0.isFinished }) ?? false }
    }

    /// The last thing the agent said, whole, for a status line or a report that has not
    /// been filed yet.
    public var lastSaid: String? {
        for entry in entries.reversed() {
            if case .said(let text) = entry.kind { return text }
        }
        return nil
    }

    /// Every file this agent has changed, newest first, no repeats. The agent page shows
    /// it beside the conversation, and it is the answer to "what has it actually done",
    /// which a terminal could never give without reading every line of it.
    public var filesTouched: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries.reversed() {
            for content in entry.tool?.content ?? [] {
                if case .diff(let diff) = content, seen.insert(diff.path).inserted {
                    out.append(diff.path)
                }
            }
        }
        return out
    }

    /// How full its context is, nil until it has said. The agent page shows it the same
    /// way Capacity shows everything else: a name and a line.
    public var contextUsed: Double? {
        guard let used, let size, size > 0 else { return nil }
        return min(1, Double(used) / Double(size))
    }

    static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let line, !line.isEmpty else { return nil }
        return line.count <= Agent.maxTitle ? line : String(line.prefix(Agent.maxTitle))
    }
}

/// The one line an agent's card and sidebar row show, folded as the updates go past and
/// never growing.
///
/// `ACPTranscript` answers the same question and holds the whole conversation to do it,
/// which is right for a page somebody is reading and wrong for the daemon, which watches
/// sixteen agents all day and is asked for this every two seconds. This keeps what it
/// needs: the last thing said, and which tool calls are still open. (T373.)
public struct ACPHeadline: Sendable, Equatable {
    private var said: String?
    /// Open calls in the order they started, so the line follows the one running now.
    private var open: [(id: String, heading: String)] = []
    private var lastFinished: String?

    public init() {}

    public static func == (a: ACPHeadline, b: ACPHeadline) -> Bool {
        a.said == b.said && a.lastFinished == b.lastFinished
            && a.open.map(\.id) == b.open.map(\.id)
            && a.open.map(\.heading) == b.open.map(\.heading)
    }

    public mutating func apply(_ update: ACP.Update) {
        switch update {
        case .message(let block):
            guard !block.text.isEmpty else { return }
            // Chunks arrive a word at a time, so a new sentence starts only after
            // something else has happened.
            said = (startedSaying ? (said ?? "") : "") + block.text
            startedSaying = true
        case .tool(let call):
            startedSaying = false
            if let at = open.firstIndex(where: { $0.id == call.toolCallID }) {
                if let heading = call.title, !heading.isEmpty { open[at].heading = heading }
                if call.isFinished {
                    lastFinished = open[at].heading
                    open.remove(at: at)
                }
            } else if !call.isFinished {
                open.append((call.toolCallID, call.heading))
            } else {
                lastFinished = call.heading
            }
        case .userMessage:
            startedSaying = false
            said = nil
        case .thought, .plan, .usage, .mode, .commands, .other:
            break
        }
    }

    private var startedSaying = false

    public mutating func apply(line: String) {
        if case .update(_, let update) = ACP.read(line: line) { apply(update) }
    }

    /// What it is doing now, else the last thing it said, else the last thing it did.
    public var line: String? {
        if let running = open.last?.heading { return running }
        if let said, let first = ACPTranscript.firstLine(said) { return first }
        return lastFinished
    }

    public var isBusy: Bool { !open.isEmpty }
}
