import SwiftUI
import SoftwareFactoryKit

/// What everybody is doing, on one page. Reading it used to mean opening each agent in
/// turn, which is fine for two agents and useless for eight.
///
/// The agent that has said nothing gets a row of its own rather than being left out. It
/// is the row you most want to see, and a page that went quiet exactly where something
/// was wrong would be worse than no page. (T288.)
struct StatusReportsView: View {
    @Environment(AppModel.self) private var model
    var selectAgent: (UUID) -> Void = { _ in }

    private var rows: [StatusReportBoard.Row] {
        StatusReportBoard.rows(in: model.snapshot, now: .now)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Status reports")
                    .font(.title2.weight(.semibold))
                if rows.isEmpty {
                    EmptyLine(
                        text: "Nobody is on the floor. Start an agent and its report lands here.",
                        symbol: "text.document")
                } else {
                    ForEach(rows) { row in
                        ReportRow(row: row) { selectAgent(row.agent.id) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One agent's news: who it is, what it is on, when it last said so, and the report
/// itself underneath.
private struct ReportRow: View {
    var row: StatusReportBoard.Row
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(row.agent.label, action: open)
                    .buttonStyle(.plain)
                    .font(.headline)
                    .help("Open \(row.agent.label)")
                Text(row.projectName ?? "No project")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                when
            }
            body(of: row)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// When it last said something, and whether that still stands. An old report is not
    /// wrong, it is just old, so it is marked rather than hidden.
    @ViewBuilder
    private var when: some View {
        if let said = row.said {
            Text(said, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(row.isFresh ? Color.secondary : Color.orange)
                .help(row.isFresh
                      ? "Filed within the hour"
                      : "Older than an hour. The factory has asked for another.")
        }
    }

    @ViewBuilder
    private func body(of row: StatusReportBoard.Row) -> some View {
        if let report = row.report {
            if !report.title.isEmpty {
                Text(report.title)
                    .font(.callout.weight(.medium))
            }
            if !report.body.isEmpty {
                MarkdownText(text: report.body)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        } else {
            Text("Nothing filed yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
