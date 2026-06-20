import AppKit
import SwiftUI
import AIMeterCore

public struct SettingsView: View {
    let store: UsageStore
    let snapshotMode: Bool

    public init(
        store: UsageStore,
        snapshotMode: Bool = false
    ) {
        self.store = store
        self.snapshotMode = snapshotMode
    }

    public var body: some View {
        Group {
            if snapshotMode {
                generalSettings
            } else {
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
                detail: "Local logs follow the selected refresh interval. Low Power Mode limits background refreshes to every 15 minutes."
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
                    Task { await store.refresh() }
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
                    Task { await store.refresh() }
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
                    Text(versionText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 36))
                    .foregroundStyle(.mint)
            }

            Divider()

            Text(
                "AI Meter reads only the local usage folders listed in Provider settings. It does not read account credentials and makes no network requests to read usage."
            )
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "Codex exposes plan windows in local session records, so AI Meter shows its live limits. Other providers, including Claude, do not expose quota in a readable local form, so they show local token totals and any budget you configure."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            updatesSection

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
    }

    private var updatesSection: some View {
        @Bindable var store = store

        return VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    store.checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.down.circle")
                }
                .disabled(!store.canCheckForUpdates)
            }

            if store.updater != nil {
                Toggle(
                    "Check for updates automatically",
                    isOn: $store.automaticallyChecksForUpdates
                )
            }

            Text(
                "AI Meter checks this project's public GitHub releases. Updates are cryptographically signed and verified before they are installed."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
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
        if !store.staleProviders.isEmpty
            || store.readings.contains(where: { $0.availability == .failed }) {
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

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        guard let build else { return "Version \(version)" }
        return "Version \(version) (\(build))"
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
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                TextField(
                                    "Optional JSON, JSONL, log file, or folder",
                                    text: $configuration.customPath
                                )
                                Button("Browse...") {
                                    chooseUsagePath()
                                }
                            }
                            pathValidationLabel
                        }
                    }

                    GridRow {
                        Text("Cost estimates")
                        Toggle(
                            "Estimate token cost",
                            isOn: $configuration.costTrackingEnabled
                        )
                    }

                    if configuration.costTrackingEnabled {
                        GridRow {
                            Text("Default model")
                            TextField(
                                "Model used when records omit one",
                                text: $configuration.defaultModelName
                            )
                        }

                        GridRow {
                            Text("USD / 1M")
                            VStack(alignment: .leading, spacing: 8) {
                                RateField(
                                    title: "Input",
                                    value: costRate.inputPerMillion
                                )
                                RateField(
                                    title: "Output",
                                    value: costRate.outputPerMillion
                                )
                                RateField(
                                    title: "Cached input",
                                    value: costRate.cachedInputPerMillion
                                )
                                RateField(
                                    title: "Cache write",
                                    value: costRate.cacheWritePerMillion
                                )
                                RateField(
                                    title: "Cache read",
                                    value: costRate.cacheReadPerMillion
                                )
                            }
                        }

                        GridRow {
                            Text("")
                            Label(
                                "Costs are estimates from local records, not provider billing statements.",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
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

    private var costRate: Binding<TokenCostRate> {
        Binding {
            configuration.customRates.first ?? TokenCostRate(
                id: "\(configuration.id.rawValue)-default",
                provider: configuration.id,
                modelName: configuration.defaultModelName,
                updatedAt: .now,
                sourceNote: "User configured"
            )
        } set: { newValue in
            var rate = newValue
            rate.provider = configuration.id
            rate.modelName = configuration.defaultModelName
            rate.currencyCode = "USD"
            rate.isEnabled = true
            rate.updatedAt = .now
            rate.sourceNote = "User configured"
            if configuration.customRates.isEmpty {
                configuration.customRates = [rate]
            } else {
                configuration.customRates[0] = rate
            }
        }
    }

    @ViewBuilder
    private var pathValidationLabel: some View {
        switch UsagePathResolver.validate(configuration.customPath) {
        case .empty:
            Text("Optional. Built-in sources remain active.")
                .foregroundStyle(.secondary)
        case let .validFile(path):
            Label(
                "Readable \(URL(fileURLWithPath: path).pathExtension.uppercased()) file",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .validDirectory:
            Label("Readable folder", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .relativePath:
            Label(
                "Use an absolute path or one beginning with ~.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case .missing:
            Label(
                "This path does not exist.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case .unreadable:
            Label(
                "AI Meter cannot read this path.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case let .unsupportedFileType(fileExtension):
            Label(
                "Unsupported file type: .\(fileExtension)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    private func chooseUsagePath() {
        let panel = NSOpenPanel()
        panel.title = "Choose AI Usage Records"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.customPath = UsagePathResolver
            .canonicalURL(for: url.path)
            .path
    }
}

private struct RateField: View {
    let title: String
    @Binding var value: Decimal

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 92, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(
                "0.00",
                value: $value,
                format: .number.precision(.fractionLength(0...6))
            )
            .frame(width: 100)
        }
    }
}
