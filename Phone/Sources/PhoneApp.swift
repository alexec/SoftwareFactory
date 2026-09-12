import SwiftUI

@main
struct PhoneApp: App {
    @State private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environment(model)
        }
    }
}
