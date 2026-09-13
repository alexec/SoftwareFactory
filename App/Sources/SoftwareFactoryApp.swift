import SwiftUI

@main
struct SoftwareFactoryApp: App {
    @State private var model = AppModel()
    /// The agents this app started, kept alive across pages.
    @State private var terminals = TerminalSessions()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(terminals)
        }
        .defaultSize(width: 980, height: 680)

        Settings {
            SettingsView()
                .environment(model)
                .environment(terminals)
        }
    }
}
