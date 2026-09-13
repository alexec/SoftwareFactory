import AppKit
import CoreGraphics
import UserNotifications
import SoftwareFactoryKit

/// One macOS notification per new question, its options as the actions, so a question
/// can be answered without opening the window. The system alert that asks permission
/// is shown only from the primer on the dashboard, never on launch.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Standing: Equatable {
        /// Not read yet. The primer waits for a real answer rather than flashing.
        case unknown
        case notAsked
        case allowed
        case denied
    }

    private(set) var standing: Standing = .unknown
    /// What the last post said, for Settings' Developer section.
    private(set) var lastPost = "nothing posted yet"
    private(set) var delivered = 0
    private let center = UNUserNotificationCenter.current()
    private var known: Set<UUID> = []
    private var primed = false
    /// Called when an action on a banner is chosen.
    var onDecision: ((UUID, UUID) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func refreshStanding() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: standing = .allowed
        case .denied: standing = .denied
        default: standing = .notAsked
        }
    }

    /// The one button on the primer calls this; it is what shows the system alert.
    func ask() async {
        do {
            let ok = try await center.requestAuthorization(options: [.alert, .sound])
            standing = ok ? .allowed : .denied
        } catch {
            standing = .denied
        }
    }

    /// Posts a banner for each open question not seen before. The first look after
    /// launch only learns what is already open, so a relaunch does not repeat old news.
    func notice(_ open: [Escalation], projects: [Project]) {
        let ids = Set(open.map(\.id))
        defer { known = ids }
        guard primed else { primed = true; return }
        guard standing == .allowed else { return }
        let fresh = open.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }

        // Every open question keeps a category, so an older banner's actions still work.
        let categories = Set(open.map { e in
            UNNotificationCategory(
                identifier: e.id.uuidString,
                actions: e.options.prefix(4).map { o in
                    UNNotificationAction(identifier: o.id.uuidString, title: o.recommended ? "\(o.title) (recommended)" : o.title)
                },
                intentIdentifiers: [])
        })
        center.setNotificationCategories(categories)

        for e in fresh {
            let content = UNMutableNotificationContent()
            let project = projects.first { $0.id == e.projectID }?.name ?? "A project"
            content.title = "\(project): \(e.question)"
            content.body = e.context.isEmpty
                ? "\(e.raisedBy) recommends \(e.recommended?.title ?? "an option")."
                : e.context
            content.categoryIdentifier = e.id.uuidString
            content.sound = .default
            center.add(UNNotificationRequest(identifier: e.id.uuidString, content: content, trigger: nil)) { error in
                _Concurrency.Task { @MainActor [weak self] in
                    self?.lastPost = error.map { "failed: \($0.localizedDescription)" } ?? "posted \(e.question) at \(Date.now.formatted(date: .omitted, time: .standard))"
                    await self?.countDelivered()
                }
            }
        }
    }

    func countDelivered() async {
        delivered = await center.deliveredNotifications().count
    }

    /// A question answered elsewhere leaves the banner behind; take it down.
    func withdraw(_ escalationID: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [escalationID.uuidString])
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        guard let escalationID = UUID(uuidString: category), let optionID = UUID(uuidString: action) else { return }
        await MainActor.run { onDecision?(escalationID, optionID) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Whether someone is at this Mac: the screen is unlocked and something was typed or
/// clicked in the last two minutes. Cheap, and right most of the time.
enum Presence {
    static let recent: TimeInterval = 120

    static var isAtTheMac: Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle < recent
    }
}
