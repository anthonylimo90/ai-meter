import SwiftUI
import AIMeterUI

@main
struct AIMeterApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra(isInserted: fallbackInserted) {
            MeterPopover(store: store)
        } label: {
            MenuBarFallbackLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: openAIInserted) {
            MeterPopover(store: store)
        } label: {
            ProviderMenuBarLabel(
                reading: store.openAIMenuBarReading,
                store: store
            )
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: claudeInserted) {
            MeterPopover(store: store)
        } label: {
            ProviderMenuBarLabel(
                reading: store.claudeMenuBarReading,
                store: store
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }

    private var fallbackInserted: Binding<Bool> {
        Binding(
            get: {
                !store.showMenuBarMeters || !store.hasLiveMenuBarReadings
            },
            set: { _ in }
        )
    }

    private var openAIInserted: Binding<Bool> {
        Binding(
            get: {
                store.showMenuBarMeters
                    && store.openAIMenuBarReading != nil
            },
            set: { _ in }
        )
    }

    private var claudeInserted: Binding<Bool> {
        Binding(
            get: {
                store.showMenuBarMeters
                    && store.claudeMenuBarReading != nil
            },
            set: { _ in }
        )
    }
}
