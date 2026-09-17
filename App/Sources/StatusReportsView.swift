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
    /// Where the project name goes. Nil is the agent on no project, which has a page of
    /// its own rather than a dead label. (T338.)
    var selectProject: (String?) -> Void = { _ in }
    /// Back to the dashboard, which is the only way here. A page reached from one place
    /// and highlighted in no sidebar row needs the way out drawn, the same as an agent's
    /// page does. (T392.)
    var back: (() -> Void)?

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
                        ReportRow(
                            row: row,
                            openAgent: { selectAgent(row.agent.id) },
                            openProject: { selectProject(row.projectID) })
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolbar {
            if let back {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: back)
                        .help("Back to the dashboard")
                }
            }
        }
    }
}

/// One agent's news: who it is, what it is on, when it last said so, and the report
/// itself underneath.
///
/// Both names open. This page is where you find out something is wrong, and the next
/// move is always to go and look at the agent or at its backlog; before this that meant
/// reading the name here and then finding it again in the sidebar by hand. (T338.)
private struct ReportRow: View {
    var row: StatusReportBoard.Row
    var openAgent: () -> Void
    var openProject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OpenLink(help: "Open \(row.agent.label)", open: openAgent) {
                    Text(row.agent.label)
                        .font(.headline)
                }
                OpenLink(help: row.projectName.map { "Open \($0)" } ?? "Open No project",
                         open: openProject) {
                    Text(row.projectName ?? "No project")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                when
            }
            body(of: row)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
        } else if let doing = row.doing {
            // An agent the factory watches is never asked for a report, so an empty row
            // would be saying it had gone quiet when its page shows the work. This is the
            // same line the card and the sidebar show. (T373.)
            Text(doing)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("Nothing filed. The factory can see this one work, so it is not asked.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Text("Nothing filed yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
