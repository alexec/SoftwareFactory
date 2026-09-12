import ActivityKit
import Foundation
import SoftwareFactoryKit

/// Keeps one Live Activity on the Lock Screen while a question is open. It shows the
/// newest open question with its options, as a notification would, with a count of the
/// others, and ends when the last is answered. The
/// activity is kept up to date while the app runs; without a push server it cannot
/// change once the phone suspends the app, so it is marked stale after a while.
@MainActor
final class LockScreen {
    nonisolated static let staleAfter: TimeInterval = 15 * 60

    private var shown: FactoryActivityAttributes.ContentState?

    func reflect(_ dashboard: Dashboard, factory: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let question = dashboard.openEscalations.last else {
            await end()
            return
        }
        let name = dashboard.projects.first { $0.id == question.projectID }?.project.name
            ?? URL(fileURLWithPath: question.projectID).lastPathComponent
        let state = FactoryActivityAttributes.ContentState(
            escalationID: question.id,
            project: name,
            raisedBy: question.raisedBy,
            question: question.question,
            context: question.context,
            options: question.options.map { .init(id: $0.id, title: $0.title, recommended: $0.recommended) },
            open: dashboard.openEscalations.count)
        guard state != shown else { return }
        await Self.show(state, factory: factory)
        shown = state
    }

    func end() async {
        await Self.endAll()
        shown = nil
    }

    // ActivityKit's handles are not Sendable, so all the talking to them happens off the
    // main actor, in one place, and nothing is kept between calls.

    nonisolated private static func show(_ state: FactoryActivityAttributes.ContentState, factory: String) async {
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(staleAfter))
        if let live = Activity<FactoryActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            await live.update(content)
        } else {
            _ = try? Activity.request(attributes: FactoryActivityAttributes(factory: factory), content: content)
        }
    }

    nonisolated private static func endAll() async {
        for live in Activity<FactoryActivityAttributes>.activities {
            await live.end(nil, dismissalPolicy: .immediate)
        }
    }
}
