import SwiftUI
import ForemanKit

enum Destination: Hashable {
    case dashboard
    case project(String)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Destination? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Dashboard", systemImage: "square.grid.2x2")
                    .tag(Destination.dashboard)

                Section("Projects") {
                    ForEach(model.dashboard.projects) { status in
                        HStack {
                            ActivityDot(activity: status.activity)
                            Text(status.project.name)
                            Spacer()
                            if status.openEscalations > 0 {
                                Text(status.openEscalations, format: .number)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.25), in: .capsule)
                            }
                        }
                        .tag(Destination.project(status.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch selection {
            case .project(let id):
                if let project = model.project(for: id) {
                    ProjectView(project: project)
                } else {
                    DashboardView()
                }
            default:
                DashboardView()
            }
        }
        .navigationTitle(title)
        .sheet(isPresented: Binding(get: { !model.hasSeenIntro }, set: { model.hasSeenIntro = !$0 })) {
            IntroSheet()
        }
    }

    private var title: String {
        if case .project(let id) = selection, let p = model.project(for: id) { return p.name }
        return "Foreman"
    }
}

struct ActivityDot: View {
    var activity: Dashboard.ProjectActivity

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(help)
    }

    private var color: Color {
        switch activity {
        case .working: .green
        case .waiting: .orange
        case .idle: .secondary.opacity(0.4)
        }
    }

    private var help: String {
        switch activity {
        case .working: "An agent is working on it"
        case .waiting: "An agent is waiting on it"
        case .idle: "Nobody is on it"
        }
    }
}
