import SwiftUI
import AIMeterCore

public struct SettingsView: View {
    let store: UsageStore

    public init(store: UsageStore) {
        self.store = store
    }

    public var body: some View {
        @Bindable var store = store

        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "slider.horizontal.3")
                }

            providerSettings
                .tabItem {
                    Label("Providers", systemImage: "square.stack.3d.up")
                }

            aboutSettings
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .scenePadding()
        .frame(width: 620, height: 520)
    }

    private var generalSettings: some View {
        @Bindable var store = store

        return VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "Refresh",
                detail: "Keep plan limits and local token totals current while AI Meter runs."
            )

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(
                        "Refresh usage automatically",
                        isOn: $store.autoRefreshEnabled
                    )

                    Toggle(
                        "Show provider meters in the menu bar",
                        isOn: $store.showMenuBarMeters
                    )

                    LabeledContent("Refresh every") {
                        Picker(
                            "Refresh every",
                            selection: $store.refreshIntervalSeconds
                        ) {
                            Text("1 minute").tag(60)
                            Text("5 minutes").tag(300)
                            Text("15 minutes").tag(900)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    .disabled(!store.autoRefreshEnabled)

                    Divider()

                    LabeledContent("Last update") {
                        Text(lastUpdatedText)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Current state") {
                        Label(
                            monitoringState.title,
                            systemImage: monitoringState.symbolName
                        )
                        .foregroundStyle(monitoringState.color)
                    }
                }
                .padding(4)
            }

            settingsHeader(
                title: "How It Updates",
                detail: "Local logs follow the selected refresh interval. Claude quota checks run at most every 15 minutes unless you choose Refresh Now. Low Power Mode also limits background refreshes to every 15 minutes."
            )

            Label(
                "The providers may update their quota counters less frequently than AI Meter refreshes.",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button {
                    Task { await store.refresh(forceClaudeQuota: true) }
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var providerSettings: some View {
        @Bindable var store = store

        return VStack(alignment: .leading, spacing: 12) {
            settingsHeader(
                title: "Provider Tracking",
                detail: "Provider-reported limits are used automatically when available. Token totals come from local records; fallback budgets are personal estimates."
            )

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach($store.configurations) { $configuration in
                        ProviderConfigurationView(configuration: $configuration)
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()

            HStack {
                Button("Restore Defaults") {
                    store.resetConfiguration()
                }

                Spacer()

                Button {
                    Task { await store.refresh(forceClaudeQuota: true) }
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Meter")
                        .font(.title.bold())
                    Text("Local AI token usage at a glance")
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 36))
                    .foregroundStyle(.mint)
            }

            Divider()

            Text(
                "AI Meter reads the local usage folders listed in Provider settings. For Claude quotas, it briefly opens the installed Claude Code client in safe mode and parses only its usage percentages and reset times. AI Meter does not read account credentials."
            )
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "Codex exposes plan windows in local session records. Claude is read from Claude Code's own usage screen. Providers without trustworthy quota data remain clearly marked as unavailable."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
    }

    private func settingsHeader(
        title: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastUpdatedText: String {
        guard let lastUpdated = store.lastUpdated else {
            return "Not refreshed yet"
        }
        return lastUpdated.formatted(
            date: .abbreviated,
            time: .standard
        )
    }

    private var monitoringState: (
        title: String,
        symbolName: String,
        color: Color
    ) {
        if store.isRefreshing {
            return (
                "Refreshing",
                "arrow.triangle.2.circlepath",
                .secondary
            )
        }
        if store.readings.contains(where: { $0.availability == .failed }) {
            return (
                "Needs attention",
                "exclamationmark.triangle.fill",
                .orange
            )
        }
        if !store.autoRefreshEnabled {
            return ("Automatic refresh paused", "pause.circle.fill", .secondary)
        }
        if !store.hasLoaded {
            return ("Waiting for first update", "clock.fill", .secondary)
        }
        return ("Monitoring", "checkmark.circle.fill", .green)
    }
}

private struct ProviderConfigurationView: View {
    @Binding var configuration: ProviderConfiguration
    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Tier")
                        TextField("Subscription tier", text: $configuration.tier)
                    }

                    GridRow {
                        Text("Fallback budget")
                        TextField(
                            "Tokens",
                            value: $configuration.tokenLimit,
                            format: .number.grouping(.never)
                        )
                    }

                    GridRow {
                        Text("Fallback window")
                        HStack {
                            TextField(
                                "Hours",
                                value: $configuration.windowHours,
                                format: .number.grouping(.never)
                            )
                            .frame(width: 90)
                            Text("hours")
                                .foregroundStyle(.secondary)
                        }
                    }

                    GridRow {
                        Text("Fallback reset")
                        DatePicker(
                            "Next reset",
                            selection: $configuration.nextResetAt
                        )
                        .labelsHidden()
                    }

                    GridRow {
                        Text("Extra folder")
                        TextField(
                            "Optional path containing JSON or JSONL usage records",
                            text: $configuration.customPath
                        )
                    }

                    GridRow {
                        Text("Built-in source")
                        Text(configuration.id.builtInPaths.joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: configuration.id.symbolName)
                        .foregroundStyle(configuration.id.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(configuration.id.name)
                            .font(.headline)
                        Text(configuration.id.sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: $configuration.isEnabled)
                        .labelsHidden()
                }
            }
        }
    }
}
