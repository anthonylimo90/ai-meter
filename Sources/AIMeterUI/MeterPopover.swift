import AppKit
import SwiftUI
import AIMeterCore

public struct MeterPopover: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings

    public init(store: UsageStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(store: store)

            if let errorMessage = store.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, MeterTheme.contentPadding)
                    .padding(.top, 12)
            }

            ProviderUsageList(store: store)
                .padding(.horizontal, MeterTheme.contentPadding)
                .padding(.top, 16)

            PopoverFooter(openSettings: openSettings)
        }
        .frame(width: MeterTheme.panelWidth)
        .background {
            ZStack {
                Color(red: 0.075, green: 0.085, blue: 0.095)
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: MeterTheme.cornerRadius,
                style: .continuous
            )
        )
        .preferredColorScheme(.dark)
        .task {
            await store.refreshIfStale(
                maxAge: store.autoRefreshEnabled ? 60 : 300
            )
        }
    }

}

private struct PopoverHeader: View {
    let store: UsageStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("AI Meter")
                    .font(.system(size: 27, weight: .bold))

                Label {
                    Text(store.statusSummary)
                        .foregroundStyle(.secondary)
                } icon: {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                        .shadow(color: statusColor.opacity(0.45), radius: 5)
                }
                .font(.system(size: 13, weight: .medium))

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(updatedText(now: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                Task { await store.refresh(forceClaudeQuota: true) }
            } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.07))
                    Circle()
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .help("Refresh local token usage")
            .accessibilityLabel("Refresh usage")
        }
        .padding(.horizontal, MeterTheme.contentPadding)
        .padding(.top, 20)
    }

    private var statusColor: Color {
        if !store.staleProviders.isEmpty {
            return .orange
        }
        if store.readings.contains(where: { $0.availability == .failed }) {
            return .red
        }
        if store.readings.contains(where: \.isLow) {
            return .orange
        }
        if !store.readings.contains(where: { $0.availability == .measured }) {
            return .secondary
        }
        return .green
    }

    private func updatedText(now: Date) -> String {
        guard let lastUpdated = store.lastUpdated else {
            return store.isRefreshing ? "Scanning local records..." : "Not refreshed yet"
        }
        let seconds = max(Int(now.timeIntervalSince(lastUpdated)), 0)
        if seconds < 15 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "Updated \(minutes)m ago" }
        return "Updated \(minutes / 60)h ago"
    }
}

private struct ProviderUsageList: View {
    let store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            if store.readings.isEmpty {
                ContentUnavailableView(
                    "No services enabled",
                    systemImage: "gauge.with.dots.needle.0percent",
                    description: Text("Enable at least one provider in Settings.")
                )
                .frame(height: 300)
            } else {
                ForEach(Array(store.readings.enumerated()), id: \.element.id) {
                    index,
                    reading in
                    ProviderUsageRow(
                        reading: reading,
                        isRefreshing: store.isRefreshing(reading.id),
                        isStale: store.staleProviders.contains(reading.id)
                    )

                    if index < store.readings.count - 1 {
                        Divider()
                            .overlay(.white.opacity(0.045))
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

private struct PopoverFooter: View {
    let openSettings: OpenSettingsAction

    var body: some View {
        HStack(spacing: 10) {
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings...", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .keyboardShortcut("q")
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, MeterTheme.contentPadding + 4)
        .frame(height: 52)
    }
}

extension MeterPopover {
    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ProviderUsageRow: View {
    let reading: ProviderUsage
    let isRefreshing: Bool
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            providerBadge

            VStack(alignment: .leading, spacing: 3) {
                Text(reading.id.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(reading.tier)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isStale {
                    Text("Last known value")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 104, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(tokenSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reading.isUnavailable ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(planSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                MeterProgressBar(
                    fraction: reading.remainingFraction ?? 0,
                    color: reading.id.accentColor,
                    isUnavailable: reading.remainingFraction == nil
                )
                .frame(height: 7)

                if let secondaryWindow = reading.secondaryPlanWindow {
                    Text(
                        "\(secondaryWindow.label): \(secondaryWindow.remainingPercent)% left"
                    )
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            VStack(alignment: .trailing, spacing: 5) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 20)
                        .help("Updating \(reading.id.name)")
                } else {
                    Text(percentText)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(percentColor)
                }

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(resetText(now: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
            .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: MeterTheme.rowHeight)
        .contentShape(Rectangle())
        .help(reading.sourceDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var providerBadge: some View {
        Group {
            if let image = reading.id.badgeCGImage {
                Canvas { context, size in
                    context.draw(
                        Image(decorative: image, scale: 1),
                        in: CGRect(origin: .zero, size: size)
                    )
                }
            } else {
                Image(systemName: reading.id.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(reading.id.accentColor)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var tokenSummary: String {
        if reading.isUnavailable {
            return "No local token data"
        }
        if reading.tokenLimit <= 0 {
            return "\(reading.usedTokens.compactTokenString) tokens"
        }
        return "\(reading.usedTokens.compactTokenString) / \(reading.tokenLimit.compactTokenString) tokens"
    }

    private var percentText: String {
        guard let remainingPercent = reading.remainingPercent else {
            return "--"
        }
        return "\(remainingPercent)%"
    }

    private var percentColor: Color {
        guard reading.remainingPercent != nil else {
            return .secondary
        }
        return reading.id.accentColor
    }

    private func resetText(now: Date = .now) -> String {
        guard reading.remainingPercent != nil else {
            return "Plan usage\nnot exposed"
        }
        let resetAt = reading.primaryPlanWindow?.resetsAt ?? reading.resetAt
        let duration = resetAt.timeIntervalSince(now)
        guard duration > 0 else { return "Reset due" }
        return "Resets in\n\(duration.compactDuration)"
    }

    private var planSummary: String {
        switch reading.planUsageSource {
        case .providerReported:
            guard let window = reading.primaryPlanWindow else {
                return "Provider-reported quota"
            }
            return "\(window.label): \(Int(window.usedPercent.rounded()))% used"
        case .configuredBudget:
            return "Personal tracking budget"
        case .unavailable:
            return "Plan limit unavailable"
        }
    }

    private var accessibilitySummary: String {
        "\(reading.id.name), \(tokenSummary), \(percentText) remaining, \(resetText())"
    }
}

private struct MeterProgressBar: View {
    let fraction: Double
    let color: Color
    let isUnavailable: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.28))
                Capsule()
                    .fill(isUnavailable ? Color.secondary.opacity(0.18) : color)
                    .frame(width: max(0, proxy.size.width * fraction))
            }
        }
        .accessibilityHidden(true)
    }
}

private extension Int {
    var compactTokenString: String {
        if self >= 10_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        }
        if self >= 1_000_000 {
            return String(format: "%.2fM", Double(self) / 1_000_000)
        }
        if self >= 100_000 {
            return String(format: "%.0fK", Double(self) / 1_000)
        }
        if self >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000)
        }
        return formatted()
    }
}

private extension TimeInterval {
    var compactDuration: String {
        let totalMinutes = max(Int(self / 60), 0)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
