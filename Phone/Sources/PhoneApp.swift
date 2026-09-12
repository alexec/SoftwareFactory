import SwiftUI

@main
struct PhoneApp: App {
    private let model = PhoneModel.shared

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environment(model)
        }
    }
}
