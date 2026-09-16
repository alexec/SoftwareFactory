import SwiftUI
import SoftwareFactoryKit

/// One agent's conversation, on the phone: what it has been doing, and a field to say
/// something to it.
///
/// The same page as the Mac's, set in the same paper and folded by the same
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
    @State private var have = 0
    @State private var words = ""
    @State private var reached = true

    private var status: Dashboard.AgentStatus? {
        model.dashboard.agents.first { $0.agent.id == agent }
    }

    private var label: String { status?.agent.label ?? "Agent" }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(transcript.page()) { row in
                        Row(row: row).id(row.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, Style.cardPadding)
                .padding(.top, Style.cardPadding)
                .padding(.bottom, 74)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.paper))
            .overlay(alignment: .bottom) { sayBox }
            .onChange(of: transcript.entries.count) { _, _ in
                withAnimation(.snappy) { scroller.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .overlay { if transcript.entries.isEmpty { nothing } }
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: agent) { await keepUp() }
    }

    private static let bottom = -1

    /// The transcript, and then whatever is added to it. Only the new lines each time:
    /// a conversation of a thousand lines does not want fetching whole every few seconds.
    private func keepUp() async {
        transcript = ACPTranscript()
        have = 0
        while !Task.isCancelled {
            if let more = await model.conversation(with: agent, after: have) {
                reached = true
                if !more.lines.isEmpty {
                    var folded = transcript
                    for line in more.lines { folded.apply(line: line) }
                    transcript = folded
                }
                have = more.total
            } else {
                reached = false
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private var nothing: some View {
        VStack(spacing: 8) {
            Text(reached ? "Nothing yet" : "Out of reach")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(Color(.ink))
            Text(reached
                 ? "Say something to \(label) below."
                 : "An agent's conversation lives on the Mac, so this page needs to be on the same network as it.")
                .font(.system(.callout, design: .serif))
                .foregroundStyle(Color(.quiet))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Style.page)
        }
    }

    private var sayBox: some View {
        HStack(spacing: 8) {
            TextField("Say something to \(label)", text: $words, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .serif))
                .submitLabel(.send)
                .onSubmit(say)
            Button("Send", systemImage: "arrow.up.circle.fill", action: say)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .disabled(!model.canTalkToAgents
                          || words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Style.card))
        .padding(.horizontal, Style.cardPadding)
        .padding(.bottom, 10)
    }

    private func say() {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        words = ""
        Task { await model.say(said, to: agent) }
    }

    /// One row, drawn the way the Mac draws it: prose in a serif on the paper, a tool call
    /// as a block set into it.
    private struct Row: View {
        var row: ACPTranscript.Shown

        var body: some View {
            switch row.entry.kind {
            case .asked(let text):
                Text(text)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(Color(.ink))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.block), in: .rect(cornerRadius: Style.panel))
                    .overlay(RoundedRectangle(cornerRadius: Style.panel)
                        .strokeBorder(Color(.rule), lineWidth: 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .said(let text):
                MarkdownText(text: text)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(Color(.ink))
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
                        .foregroundStyle(Color(.ink))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let alsoRan = row.alsoRan {
                        Text(alsoRan).font(.caption).foregroundStyle(Color(.quiet))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.block), in: .rect(cornerRadius: Style.panel))
            }
        }

        @ViewBuilder
        private func mark(_ call: ACP.ToolCall) -> some View {
            switch call.status {
            case .completed: Image(systemName: "checkmark").foregroundStyle(Color(.quiet))
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            default: ProgressView().controlSize(.small)
            }
        }
    }
}
