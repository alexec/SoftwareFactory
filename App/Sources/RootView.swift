import SwiftUI
import SoftwareFactoryKit

enum Destination: Hashable {
    case floor
    case resources
    case factory
    case project(String)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Destination? = .floor
    // The macOS place for this is a right-click on the row, not a button on its own
    // page. (Alex, 12 Sep 2026.)
    @State private var removing: Project?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Floor", systemImage: "square.grid.2x2")
                    .tag(Destination.floor)
                Label("Resources", systemImage: "lock.rectangle.stack")
                    .tag(Destination.resources)
                Label("Capacity", systemImage: "building.2")
                    .tag(Destination.factory)

                // Alex, 12 Sep 2026: the count in the heading.
                Section("Projects (\(model.dashboard.projects.count))") {
                    ForEach(model.dashboard.projects) { status in
                        HStack {
                            ActivityDot(activity: status.project.onHold ? .idle : status.activity)
                                .help(status.project.onHold ? "On hold" : "")
                            Text(status.project.name)
                                .foregroundStyle(status.project.onHold ? .secondary : .primary)
                            Spacer()
                            ProgressNumbers(status: status, compact: true)
                            if status.openEscalations > 0 {
                                Text(status.openEscalations, format: .number)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.25), in: .capsule)
                            }
                        }
                        .tag(Destination.project(status.id))
                        .contextMenu {
                            Button("Remove project…", role: .destructive) { removing = status.project }
                                .disabled(!model.openTasks(in: status.project).isEmpty)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .confirmationDialog("Remove \(removing?.name ?? "") from the factory?",
                                 isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove", role: .destructive) {
                    if let removing { model.removeProject(removing) }
                    removing = nil
                }
            } message: {
                Text("It leaves every list, with its done and parked tasks. Nothing is deleted from disk.")
            }
        } detail: {
            switch selection {
            case .resources:
                ResourcesView()
            case .factory:
                FactoryView()
            case .project(let id):
                if let project = model.project(for: id) {
                    ProjectView(project: project)
                } else {
                    FloorView()
                }
            default:
                FloorView()
            }
        }
        .navigationTitle(title)
        .sheet(isPresented: Binding(get: { !model.hasSeenIntro }, set: { model.hasSeenIntro = !$0 })) {
            IntroSheet()
        }
    }

    private var title: String {
        if case .project(let id) = selection, let p = model.project(for: id) { return p.name }
        if case .resources = selection { return "Resources" }
        if case .factory = selection { return "Capacity" }
        return "Software Factory"
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
        case .waiting: "An agent is on it and waiting"
        case .idle: "Nobody is on it"
        }
    }
}
