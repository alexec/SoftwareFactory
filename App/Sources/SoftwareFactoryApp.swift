import SwiftUI

@main
struct SoftwareFactoryApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 980, height: 680)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
