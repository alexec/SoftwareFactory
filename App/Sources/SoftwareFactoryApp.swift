import SwiftUI

@main
struct SoftwareFactoryApp: App {
    @State private var model: AppModel
    /// The agents this app started, kept alive across pages.
    @State private var terminals = TerminalSessions()
    /// The daemon holding every ACP agent, and this app's side of it. (T373.)
    @State private var floor: Floor

    /// Made here rather than as a default, and there is no default: a stored property's
    /// default is assigned before init runs and then thrown away, so `AppModel()` would
    /// be built twice and the second one would find port 4747 already taken by the first.
    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _floor = State(initialValue: Floor(store: model.store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(terminals)
                .environment(floor)
        }
        .defaultSize(width: 980, height: 680)

        Settings {
            SettingsView()
                .environment(model)
                .environment(terminals)
                .environment(floor)
        }
    }
}
