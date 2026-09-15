import SwiftUI
import SoftwareFactoryKit

/// What is being worked on right now, across every project.
///
/// The floor says who is here and each project says what is left, but the question
/// between them, what is actually underway, meant opening every project in turn. The
/// tasks nobody is on sit at the top: an agent took one and then stopped or was deleted,
/// and it has been in progress with nobody coming back to it ever since. (T287.)
struct InProgressView: View {
    @Environment(AppModel.self) private var model
    var openProject: (String) -> Void = { _ in }

    private var rows: [WorkInProgress.Row] { WorkInProgress.rows(in: model.snapshot) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("In progress")
                    .font(.title2.weight(.semibold))
                if rows.isEmpty {
                    EmptyLine(
                        text: "Nothing is being worked on. Start an agent on a backlog and it turns up here.",
                        symbol: "hammer")
                } else {
                    ForEach(rows) { row in
                        InProgressRow(row: row) { openProject(row.task.projectID) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One task underway: what it is, whose project, who is on it and how long for.
private struct InProgressRow: View {
    var row: WorkInProgress.Row
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let number = row.task.label {
                    Text(number)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(row.task.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(row.since, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Last touched")
            }
            HStack(spacing: 8) {
                Button(row.projectName, action: open)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Open \(row.projectName)")
                if let agent = row.agentLabel {
                    Text(agent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    // The row worth reading: in progress, and nobody on it.
                    Text("Nobody is on it")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .help("It was claimed by an agent that has gone. Take it back from the project's backlog.")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Style.card))
    }
}
