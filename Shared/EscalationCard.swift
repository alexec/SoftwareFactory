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
    var place = Place.inAList
    var model: any Deciding
    @State private var words = ""

    /// Where this card is being drawn, which is what decides how much of it is needed.
    ///
    /// In a list it is one question among several, on a page about something else, and it
    /// has to be picked out and placed: its own edges, the alarm colour, a line saying
    /// whose it is and when, and which task it is stopping.
    ///
    /// At the foot of an agent's page every one of those is already on screen. The
    /// conversation that led to the question is directly above it, the sidebar says whose
    /// page this is and what it holds, it is the only thing down there so nothing has to be
    /// picked out from anything, and the field it replaced had no card around it. What was
    /// left was eight nested boxes to ask one question in. (Alex, 16 Sep 2026: the card is
    /// complex looking.)
    enum Place {
        case inAList
        case atTheFoot

        var isInAList: Bool { self == .inAList }
    }

    var body: some View {
        if place.isInAList {
            asked
                .padding(Style.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(tint: escalation.isOpen ? .orange : nil)
                .animation(.snappy, value: escalation.decision)
        } else {
            asked
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.snappy, value: escalation.decision)
        }
    }

    private var asked: some View {
        VStack(alignment: .leading, spacing: 12) {
            if place.isInAList {
                heading
            }
            Text(escalation.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if place.isInAList, let stops {
                Label("Stops: \(stops)", systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
            if !escalation.context.isEmpty {
                Text(escalation.context)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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

    /// The choices. One surface with the options ruled off inside it, rather than each on a
    /// sheet of its own: three choices used to be three pieces of glass stacked inside a
    /// tinted card inside a page, which is four materials deep to answer a yes or no. A list
    /// of choices is one list. The edges come off altogether at the foot of an agent's page,
    /// where there is nothing to tell them apart from. (Alex, 16 Sep 2026.)
    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(escalation.options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider() }
                OptionButton(option: option, number: index + 1,
                             isChosen: option.id == escalation.decision?.optionID) {
                    model.chose(escalation, option, note: words)
                    words = ""
                }
            }
        }
        .background(place.isInAList ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: Style.panel))
        .overlay {
            RoundedRectangle(cornerRadius: Style.panel).strokeBorder(.separator, lineWidth: 1)
        }
    }

    /// One field, two uses: typed before choosing an option it rides along as a note; sent
    /// on its own it is the answer, none of the options. (Alex, 12 Sep 2026.)
    @ViewBuilder
    private var note: some View {
        if let decision = escalation.decision, !decision.note.isEmpty {
            Label(decision.note, systemImage: escalation.answeredInOwnWords ? "text.bubble" : "note.text")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // The same send the prompt field has. It was a button reading "Answer with
            // this", which is a sentence where every other field in the app has an arrow,
            // and the longest thing on the row was the label on the control rather than
            // what you typed. (Alex, 16 Sep 2026: "use the same send icon as the normal
            // prompt input".)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("A note for the agent, or your own answer", text: $words, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.callout)
                Button("Send", systemImage: "arrow.up.circle.fill") {
                    model.answered(escalation, with: words)
                    words = ""
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
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
///
/// **Numbered, and no radio button** (Alex, 16 Sep 2026: "Show a number next to each
/// answer. and don't show the radio button. These are normal buttons."). A radio circle
/// says pick one of these and then confirm, and there is nothing to confirm with: pressing
/// one answers the question and the agent is told. So it is a numbered button, and the
/// number is what you refer to it by when you say "the second one" to somebody.
///
/// The tick stays on the one that was chosen, because a card with a decision on it is a
/// record of what you decided rather than a question, and that is the only state left.
private struct OptionButton: View {
    var option: Escalation.Option
    var number: Int
    var isChosen: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if isChosen {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else {
                    Text("\(number)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
                            .foregroundStyle(.secondary)
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
        // The one chosen, marked on the row rather than by a sheet of tinted glass under
        // it. The green tick beside it already says which it was.
        .background(isChosen ? Color.green.opacity(0.12) : .clear)
        .help(option.recommended ? "The agent's recommendation" : "Choose this")
    }
}
