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
        case .other: break
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

    /// What the factory said to the agent, written down as we say it. The agent does not
    /// echo our prompts back except on a replay, so without this a page shows an agent
    /// answering questions nobody asked.
    public mutating func weSaid(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
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
