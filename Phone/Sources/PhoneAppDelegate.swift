import UIKit

/// Remote notifications: iCloud sends a silent push when the Mac writes a question, a
/// task or a project; the app wakes, reads the store and does the rest itself.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        _Concurrency.Task { @MainActor in await PhoneModel.shared.cloud.subscribe() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        _Concurrency.Task { @MainActor in PhoneModel.shared.cloud.noteRegistrationFailure(error) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await PhoneModel.shared.pushArrived()
        return .newData
    }
}
