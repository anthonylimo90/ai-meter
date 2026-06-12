import SwiftUI
import AIMeterUI

@main
struct AIMeterApp: App {
    @State private var store = UsageStore()

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
