import SwiftUI
import AIMeterUI

@main
struct AIMeterApp: App {
    @State private var store: UsageStore
    private let updater: SparkleUpdater

    init() {
        let store = UsageStore()
        let updater = SparkleUpdater()
        store.updater = updater
        _store = State(initialValue: store)
        self.updater = updater
    }

    var body: some Scene {
        MenuBarExtra {
            MeterPopover(store: store)
        } label: {
            AIMeterMenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
