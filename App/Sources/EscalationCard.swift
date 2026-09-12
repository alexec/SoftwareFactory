import SwiftUI
import SoftwareFactoryKit

/// One question from an agent, its options, and the decision once it is made. Clicking
/// an option records it; clicking another changes the record.
struct EscalationCard: View {
    @Environment(AppModel.self) private var model
    var escalation: Escalation
    var showsProject: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Spacer()
                if let chosen = escalation.chosen, let decision = escalation.decision {
                    Label("\(chosen.title) · \(decision.at, format: .relative(presentation: .named))", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }

            Text(escalation.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let task = escalation.taskID.flatMap({ id in model.snapshot.tasks.first { $0.id == id } }) {
                Label("Stops: \(task.title)", systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !escalation.context.isEmpty {
                Text(escalation.context)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(escalation.options) { option in
                        OptionButton(option: option, isChosen: option.id == escalation.decision?.optionID) {
                            model.decide(escalation, option)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            escalation.isOpen ? .regular.tint(.orange.opacity(0.12)) : .regular,
            in: .rect(cornerRadius: 18))
        .animation(.snappy, value: escalation.decision)
    }
}

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
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(isChosen ? .regular.tint(.green.opacity(0.15)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 12))
        .help(option.recommended ? "The agent's recommendation" : "Choose this")
    }
}
