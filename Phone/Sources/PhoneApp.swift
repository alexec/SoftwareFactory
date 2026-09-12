import SwiftUI

@main
struct PhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    private let model = PhoneModel.shared

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environment(model)
        }
    }
}
