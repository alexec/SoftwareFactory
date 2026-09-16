import SwiftUI
import SoftwareFactoryKit

/// How an agent is doing, as a dot. One of these rather than one per app: it was drawn in
/// both and the two had already drifted, a stopped agent being grey on the Mac and red on
/// the phone. The same agent cannot be two colours depending on which screen you are
/// looking at. (Alex, 16 Sep 2026: make the iPhone layout and colour the same.)
struct AgentActivityDot: View {
    var activity: Dashboard.AgentActivity
    var size = 8.0

    var body: some View {
        Circle()
            .fill(Self.color(activity))
            .frame(width: size, height: size)
            .help(Self.help(activity))
    }

    static func color(_ activity: Dashboard.AgentActivity) -> Color {
        switch activity {
        case .working: .green
        case .blocked: .orange
        case .waiting: Color(.faint)
        case .idle: Color(.ink)
        // Not red: a stopped agent is a normal end, and Start picks it back up. Red is
        // for a thing that went wrong.
        case .stopped: Color(.quiet)
        }
    }

    static func help(_ activity: Dashboard.AgentActivity) -> String {
        switch activity {
        case .working: "Working"
        case .blocked: "Its task is blocked"
        case .waiting: "Waiting for a task, for mail, or for you"
        case .idle: "Idle"
        case .stopped: "Stopped"
        }
    }
}
