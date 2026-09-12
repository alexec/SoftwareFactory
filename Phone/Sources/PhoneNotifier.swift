import UIKit
import UserNotifications
import SoftwareFactoryKit

/// One notification per new question, its options as the actions, so a question can
/// be answered from the banner wherever the phone is. The system alert that asks
/// permission is shown only from the primer, never on launch. Questions reach a phone
/// away from the Mac through iCloud: a silent push wakes the app, which reads the store
/// and posts the banner itself, so the banner carries the options.
@MainActor
final class PhoneNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Standing: Equatable {
        case unknown
        case notAsked
        case allowed
        case denied
    }

    private(set) var standing: Standing = .unknown
    private(set) var lastPost = "nothing posted yet"
    private let center = UNUserNotificationCenter.current()
    /// Questions already announced, kept across launches: a push may launch the app
    /// cold, and the first look must still know what is news.
    private var announced: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.announcedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.announcedKey) }
    }
    private var hasEverLooked: Bool { UserDefaults.standard.object(forKey: Self.announcedKey) != nil }
    static let announcedKey = "announcedEscalationIDs"

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
        if standing == .allowed { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// The one button on the primer calls this; it is what shows the system alert.
    func ask() async {
        do {
            let ok = try await center.requestAuthorization(options: [.alert, .sound])
            standing = ok ? .allowed : .denied
        } catch {
            standing = .denied
        }
        if standing == .allowed { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Posts a banner for each open question not announced before. The very first look
    /// only learns what is already open, so a fresh install does not repeat old news.
    func notice(_ open: [Escalation], projects: [Project]) {
        let ids = Set(open.map { $0.id.uuidString })
        guard hasEverLooked else { announced = ids; return }
        let fresh = open.filter { !announced.contains($0.id.uuidString) }
        announced = announced.union(ids).intersection(ids.union(announced.suffixKeeping(200)))
        guard standing == .allowed, !fresh.isEmpty else { return }

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
            content.interruptionLevel = .timeSensitive
            center.add(UNNotificationRequest(identifier: e.id.uuidString, content: content, trigger: nil)) { error in
                _Concurrency.Task { @MainActor [weak self] in
                    self?.lastPost = error.map { "failed: \($0.localizedDescription)" } ?? "posted \(e.question) at \(Date.now.formatted(date: .omitted, time: .standard))"
                }
            }
        }
    }

    /// A question answered anywhere takes its banner down.
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
        await PhoneModel.shared.decide(escalationID: escalationID, optionID: optionID)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

private extension Set where Element == String {
    /// The set itself; a bound on growth is kept by intersection with what is open.
    func suffixKeeping(_ n: Int) -> Set<String> { count > n ? Set(Array(self).suffix(n)) : self }
}
