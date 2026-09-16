import SwiftUI
import SoftwareFactoryKit

/// What a question's card needs from whichever app is drawing it.
///
/// The card asks for the store it should read and says what the person did; it knows
/// nothing else about either app. Both models already answer the first two, and the last
/// two are named for what happened rather than for what the model does, so neither app
/// has to rename a method it already has. (T394.)
@MainActor
protocol Deciding: AnyObject {
    var snapshot: Snapshot { get }
    func project(for id: String) -> Project?
    /// An option chosen, with whatever was typed above it riding along as a note.
    func chose(_ escalation: Escalation, _ option: Escalation.Option, note: String)
    /// Words sent on their own: the answer, none of the options.
    func answered(_ escalation: Escalation, with words: String)
}

/// One question from an agent, its options, and the decision once it is made. Choosing an
/// option records it; choosing another changes the record.
///
/// One card, on the Mac and on the phone. It was written twice, and the two had drifted
/// the way two copies do: the phone's had no answered state, so a question decided from
/// the Lock Screen still looked open on the page behind it, and it never said which task
/// the question was stopping. The phone gains both here. (T394.)
struct EscalationCard: View {
    var escalation: Escalation
    /// Whose question it is. Off on a project's own page, where the name is the heading.
    var showsProject = false
    var model: any Deciding
    @State private var words = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            Text(escalation.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let stops {
                Label("Stops: \(stops)", systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(Color(.alarm))
            }
            if !escalation.context.isEmpty {
                Text(escalation.context)
                    .font(.callout)
                    .foregroundStyle(Color(.quiet))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The thing to read before deciding, on the question rather than somewhere
            // else: a document filed with it, or the page it points at.
            if let artifact {
                ArtifactCard(artifact: artifact)
            } else if !escalation.link.isEmpty {
                ReviewLink(link: escalation.link)
            }
            options
            note
        }
        .padding(Style.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            escalation.isOpen ? .regular.tint(Color(.alarm).opacity(0.14)) : .regular,
            in: .rect(cornerRadius: Style.card))
        .animation(.snappy, value: escalation.decision)
    }

    private var heading: some View {
        HStack(spacing: 8) {
            if showsProject, let project = model.project(for: escalation.projectID) {
                Text(project.name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
            Text("\(escalation.raisedBy) · \(escalation.raised, format: .relative(presentation: .named))")
                .font(.caption)
                .foregroundStyle(Color(.quiet))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let decision = escalation.decision {
                Label("\(escalation.chosen?.title ?? "In your own words") · \(decision.at, format: .relative(presentation: .named))",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
        }
    }

    private var options: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(escalation.options) { option in
                    OptionButton(option: option, isChosen: option.id == escalation.decision?.optionID) {
                        model.chose(escalation, option, note: words)
                        words = ""
                    }
                }
            }
        }
    }

    /// One field, two uses: typed before choosing an option it rides along as a note; sent
    /// on its own it is the answer, none of the options. (Alex, 12 Sep 2026.)
    @ViewBuilder
    private var note: some View {
        if let decision = escalation.decision, !decision.note.isEmpty {
            Label(decision.note, systemImage: escalation.answeredInOwnWords ? "text.bubble" : "note.text")
                .font(.callout)
                .foregroundStyle(Color(.quiet))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("A note for the agent, or your own answer", text: $words, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.callout)
                Button("Answer with this") {
                    model.answered(escalation, with: words)
                    words = ""
                }
                .buttonStyle(.glass)
                .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send these words as the answer instead of an option")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Style.panel))
        }
    }

    private var stops: String? {
        escalation.taskID.flatMap { id in model.snapshot.tasks.first { $0.id == id } }?.title
    }

    private var artifact: Artifact? {
        escalation.artifactID.flatMap { id in model.snapshot.artifacts.first { $0.id == id } }
    }
}

/// One option. The recommendation is marked and never chosen for you.
private struct OptionButton: View {
    var option: Escalation.Option
    var isChosen: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(option.title)
                            .font(.body.weight(.medium))
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
                            .font(.callout)
                            .foregroundStyle(Color(.quiet))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // A finger needs 44 points wherever it is, and the Mac's rows are already
            // taller than this, so one number does for both.
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(isChosen ? .regular.tint(.green.opacity(0.15)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: Style.panel))
        .help(option.recommended ? "The agent's recommendation" : "Choose this")
    }
}
