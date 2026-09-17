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
        Group {
            if Self.isHollow(activity) {
                Circle().strokeBorder(Self.color(activity), lineWidth: 1.5)
            } else {
                Circle().fill(Self.color(activity))
            }
        }
        .frame(width: size, height: size)
        .help(Self.help(activity))
    }

    /// Green working, orange wanting you, blue finished, and nothing at all for an agent
    /// that has stopped or been put away. (T423, Alex, 15 Sep 2026: green, blue, orange,
    /// and a black circle for stopped.)
    ///
    /// Stopped is drawn as an outline rather than a filled black dot, because a filled
    /// black dot is invisible in dark mode and a filled white one would be the loudest
    /// thing on the row. An empty circle reads as absence both ways up, which is what a
    /// black circle was being asked to say.
    static func color(_ activity: Dashboard.AgentActivity) -> Color {
        switch activity {
        case .working: .green
        case .askingYou: Color.orange
        case .finished: .blue
        // Not red: a stopped agent is a normal end, and Start picks it back up. Red is
        // for a thing that went wrong.
        case .stopped: Color.secondary
        }
    }

    static func isHollow(_ activity: Dashboard.AgentActivity) -> Bool { activity == .stopped }

    static func help(_ activity: Dashboard.AgentActivity) -> String {
        switch activity {
        case .working: "Working"
        case .askingYou: "It wants an answer from you"
        case .finished: "Finished, and waiting for something to do"
        case .stopped: "Stopped"
        }
    }
}

/// A project's dot: the same four colours an agent's uses, because a project is whatever
/// its agents are. Nobody on it draws nothing, and on hold says so.
///
/// It lived in the Mac's own sources and the phone drew its own version beside it with two
/// of the four colours, which is how a vocabulary comes apart. (T423.)
struct ActivityDot: View {
    var activity: Dashboard.ProjectActivity
    var isEmpty = false
    var onHold = false

    var body: some View {
        Group {
            if isEmpty && !onHold {
                Circle().fill(.clear)
            } else if AgentActivityDot.isHollow(activity) || onHold {
                Circle().strokeBorder(AgentActivityDot.color(activity), lineWidth: 1.5)
            } else {
                Circle().fill(AgentActivityDot.color(activity))
            }
        }
        .frame(width: 8, height: 8)
        .help(help)
    }

    private var help: String {
        if onHold { return "On hold" }
        if isEmpty { return "Nobody is on it" }
        return AgentActivityDot.help(activity)
    }
}
